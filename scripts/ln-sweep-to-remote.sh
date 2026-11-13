#!/usr/bin/env bash
###
# Find, and with `sweep` bring back, a node's own outputs of channels that its
# peer closed unilaterally and that the node itself does not claim
# (docs/lightning-recovery.md): after `emergencyrecover` on Core Lightning
# v26.06.10, and for outputs of earlier such closes once the database is gone.
#
#   scripts/ln-sweep-to-remote.sh <node> <peer id> <channels> [sweep]
#
#   node       alice | bob: whose money
#   peer id    the node id of the channel's other side
#   channels   how many channel numbers to try (1..N; the number is the "#3"
#              in "chan#3" in the logs of either side, counted per node)
#   sweep      send what was found to a new address of the node; without it
#              the outputs are only listed
#
#   CONTEXT   kubectl context of the cluster (required)
#   FEE_SAT   fee of the sweep (default 400)
#
# Such an output (`to_remote` of an anchor channel) pays to a key made from
# the node's hsm_secret, the peer id and the channel number, behind a
# one-block delay: `<key> OP_CHECKSIGVERIFY 1 OP_CHECKSEQUENCEVERIFY`.
# lightning-hsmtool derives the key; a temporary wallet in the chain's
# bitcoind finds and signs. The keys go through pipes only: not to this
# machine's disk, not to the terminal. This is for regtest: on a real network
# the signing wallet belongs on a machine you trust with the keys.
###
set -euo pipefail

: "${CONTEXT:?set CONTEXT to the kubectl context of the cluster}"
node=${1:-} peer=${2:-} last=${3:-} mode=${4:-list}
case "$node:$mode" in alice:list | alice:sweep | bob:list | bob:sweep) ;; *) node= ;; esac
if [ -z "$node" ] || [ -z "$peer" ] || ! [ "$last" -ge 1 ] 2>/dev/null; then
  echo "usage: CONTEXT=... $0 alice|bob <peer id> <channels> [sweep]" >&2
  exit 2
fi
wallet=ln-sweep

k() { kubectl --context "$CONTEXT" -n lightning "$@"; }
bc() { k exec -i bitcoind-0 -c bitcoind -- bitcoin-cli -regtest -datadir=/data "$@"; }
json() { python3 -I -c "import json, sys; r = json.load(sys.stdin); $1"; }
# A private key in hex, on stdin, as the descriptor of its to_remote output.
descriptor() {
  python3 -I -c '
import hashlib, sys
alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
raw = b"\xef" + bytes.fromhex(sys.stdin.read().strip()) + b"\x01"  # regtest, compressed
raw += hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]
n, wif = int.from_bytes(raw, "big"), ""
while n:
    n, r = divmod(n, 58)
    wif = alphabet[r] + wif
print("wsh(and_v(v:pk(%s),older(1)))" % wif)'
}
cleanup() {
  bc unloadwallet "$wallet" >/dev/null 2>&1 || true
  k exec bitcoind-0 -c bitcoind -- rm -rf "/data/regtest/wallets/$wallet"
}
trap cleanup EXIT

bc createwallet "$wallet" false true >/dev/null # with private keys, blank
for n in $(seq "$last"); do
  desc=$(k exec "cln-$node-0" -c lightningd -- \
    lightning-hsmtool derivetoremote "$peer" "$n" /data/regtest/hsm_secret | sed 's/^privkey *: *//' | descriptor)
  sum=$(printf '%s\n' "$desc" | bc -stdin getdescriptorinfo | json 'print(r["checksum"])')
  # timestamp 0: look through the whole chain
  printf '[{"desc":"%s#%s","timestamp":0}]\n' "$desc" "$sum" |
    bc -stdin -rpcwallet="$wallet" importdescriptors | json 'assert r[0]["success"], r'
  unset desc
done

unspent=$(bc -rpcwallet="$wallet" listunspent)
echo "$unspent" | json '
for u in r: print("%s:%d  %.0f sat" % (u["txid"], u["vout"], u["amount"] * 1e8))
print("%d output(s), %.0f sat" % (len(r), sum(u["amount"] for u in r) * 1e8))'
if [ "$mode" = list ] || [ "$unspent" = "[]" ] || [ -z "$(echo "$unspent" | tr -d '[] \n')" ]; then exit 0; fi

addr=$(k exec "cln-$node-0" -c lightningd -- lightning-cli --lightning-dir=/data -F newaddr |
  grep -E '^(bech32|p2tr)=' | head -n 1 | cut -d= -f2)
# By hand, with sequence 1 on every input: the wallet's own `sendall` leaves
# the sequence at its default, which the one-block delay rejects.
inputs=$(echo "$unspent" | json 'print(json.dumps([{"txid": u["txid"], "vout": u["vout"], "sequence": 1} for u in r]))')
amount=$(echo "$unspent" | FEE_SAT=${FEE_SAT:-400} json '
import os
print("%.8f" % ((round(sum(u["amount"] for u in r) * 1e8) - int(os.environ["FEE_SAT"])) / 1e8))')
psbt=$(bc createpsbt "$inputs" "[{\"$addr\":$amount}]")
hex=$(bc -rpcwallet="$wallet" walletprocesspsbt "$psbt" true ALL true true | json 'assert r["complete"], "not fully signed"; print(r["hex"])')
echo "sent to $addr: $(bc sendrawtransaction "$hex")"
echo "it shows in the node's listfunds once a block confirms it"
