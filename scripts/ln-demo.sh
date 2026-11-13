#!/usr/bin/env bash
###
# A payment over Lightning on the regtest nodes (gitops/workloads/lightning):
#
#   open   fund alice on chain, open a 1,000,000 sat channel alice -> bob,
#          wait until it is CHANNELD_NORMAL (skipped if one is already open)
#   pay    bob makes an invoice, alice pays it, both balances are printed
#   close  close the channel cooperatively and confirm the close on chain
#
#   CONTEXT   kubectl context of the cluster (required)
#
# Blocks are mined on demand here (to an anyone-can-spend script, as the
# chain's own miner does), so a step does not wait for the 10-minute miner.
# Safe to run again: each step checks what is already there.
###
set -euo pipefail

: "${CONTEXT:?set CONTEXT to the kubectl context of the cluster}"
step=${1:-}
case "$step" in open | pay | close) ;; *)
  echo "usage: CONTEXT=... $0 open|pay|close" >&2
  exit 2
  ;;
esac

k() { kubectl --context "$CONTEXT" -n lightning "$@"; }
# lightning-cli on a node, flat key=value output
cli() {
  local node=$1
  shift
  k exec "cln-$node-0" -c lightningd -- lightning-cli --lightning-dir=/data -F "$@"
}
field() { sed -n "s/^$1=//p" | head -n 1; }
mine() {
  k exec bitcoind-0 -c bitcoind -- \
    bitcoin-cli -regtest -datadir=/data generatetodescriptor "$1" 'raw(51)#8lvh9jxk' >/dev/null
}
# Wait until a command's output matches, mining a block each round so the
# nodes see the chain move. Gives up after about five minutes.
wait_for() {
  local what=$1 pattern=$2
  shift 2
  for _ in $(seq 60); do
    # not grep -q: it stops reading at the first match, the command then
    # dies of SIGPIPE, and with pipefail the match counts as a failure
    if "$@" | grep "$pattern" >/dev/null; then return 0; fi
    mine 1
    sleep 5
  done
  echo "timed out waiting for $what" >&2
  return 1
}
# The state of each channel alice -> bob that is not closed yet, one a line.
# A closed channel stays listed as ONCHAIN for a while, next to a new one.
channel_states() {
  cli alice listpeerchannels "$bob_id" | sed -n 's/^channels\[[0-9]*\]\.state=//p' | grep -vx ONCHAIN || true
}
# "closed" once no channel is left that is not on chain.
all_closed() { [ -n "$(channel_states)" ] || echo closed; }
balances() {
  for n in alice bob; do
    printf '%-6s on chain %10s sat   in channels %10s sat\n' "$n" \
      "$(cli "$n" listfunds | awk -F= '
          /^outputs\[[0-9]+\]\.amount_msat=/ { split($1, a, /[][]/); amt[a[2]] = $2 }
          /^outputs\[[0-9]+\]\.status=/      { split($1, a, /[][]/); st[a[2]] = $2 }
          END { for (i in amt) if (st[i] == "confirmed") s += amt[i]; printf "%.0f", int(s / 1000) }')" \
      "$(cli "$n" listfunds | sed -n 's/^channels\[[0-9]*\]\.our_amount_msat=//p' |
        awk '{ s += $1 } END { printf "%.0f", int(s / 1000) }')"
  done
}

bob_id=$(cli bob getinfo | field id)

case "$step" in
open)
  if channel_states | grep -x CHANNELD_NORMAL >/dev/null; then
    echo "a channel alice -> bob is already open"
  else
    echo "1/4 fund alice: 101 blocks to her address (coinbase needs 100 to mature)"
    addr=$(cli alice newaddr | field bech32)
    k exec bitcoind-0 -c bitcoind -- \
      bitcoin-cli -regtest -datadir=/data generatetoaddress 101 "$addr" >/dev/null
    wait_for "alice's funds" 'status=confirmed' cli alice listfunds

    echo "2/4 connect alice to bob"
    cli alice connect "$bob_id" cln-bob.lightning.svc 9735 >/dev/null

    echo "3/4 open a 1,000,000 sat channel"
    cli alice fundchannel "$bob_id" 1000000 | field txid | sed 's/^/    funding txid /'

    echo "4/4 confirm it (6 blocks)"
    mine 6
    wait_for "CHANNELD_NORMAL" CHANNELD_NORMAL channel_states
    echo "channel open"
    echo "the nodes' channel lists changed: run scripts/ln-backup.sh alice, then bob"
  fi
  ;;
pay)
  label="demo-$(date +%s)"
  bolt11=$(cli bob invoice 50000000 "$label" "ln-demo payment" | field bolt11)
  echo "bob's invoice for 50,000 sat: ${bolt11:0:40}..."
  cli alice pay "$bolt11" | grep -E '^(status|amount_sent_msat|payment_preimage)=' | sed 's/^/    /'
  ;;
close)
  cli alice close "$bob_id" | field type | sed 's/^/close type: /'
  mine 1
  wait_for "the close on chain" closed all_closed
  echo "channel closed"
  ;;
esac
balances
