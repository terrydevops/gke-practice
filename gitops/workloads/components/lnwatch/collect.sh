#!/bin/bash
# Core Lightning node metrics for Prometheus, in its text format. Runs next to
# lightningd in the same pod and talks to it through the RPC socket under
# /data. The chain height comes from bitcoind's RPC, so a node that stops
# following the chain shows. Written to a file that the metrics container
# serves; rewritten every $INTERVAL seconds, atomically.
#
# Env: NODE (label), RPC_PASSWORD (bitcoind), INTERVAL (default 15)
set -u
OUT=/metrics/ln.prom
INTERVAL=${INTERVAL:-15}
CLI=(lightning-cli --lightning-dir=/data -F)
STATES="CHANNELD_AWAITING_LOCKIN CHANNELD_NORMAL CHANNELD_SHUTTING_DOWN CLOSINGD_SIGEXCHANGE CLOSINGD_COMPLETE AWAITING_UNILATERAL FUNDING_SPEND_SEEN ONCHAIN"

# One field of `lightning-cli -F` output (key=value lines), first match.
field() { sed -n "s/^$1=//p" | head -n 1; }
# Sum of every value of a field across a list, msat, as satoshis.
sum_sat() { sed -n "s/^$1=//p" | awk '{ s += $1 } END { printf "%d", s / 1000 }'; }

while :; do
  tmp=$OUT.tmp
  : > "$tmp"
  # m <name> <value> [extra labels, starting with a comma]
  m() { echo "$1{node=\"$NODE\"${3:-}} ${2:-0}" >> "$tmp"; }

  if info=$("${CLI[@]}" getinfo 2>/dev/null); then
    m cln_up 1
    m cln_blockheight "$(echo "$info" | field blockheight)"
    m cln_peers "$(echo "$info" | field num_peers)"
    # Set while lightningd or bitcoind is still catching up with the chain.
    if echo "$info" | grep -q '^warning_bitcoind_sync=\|^warning_lightningd_sync='; then
      m cln_chain_sync_warning 1
    else
      m cln_chain_sync_warning 0
    fi

    funds=$("${CLI[@]}" listfunds)
    # Confirmed outputs only: the index ties each amount to its status.
    m cln_funds_onchain_sat "$(echo "$funds" | awk -F= '
        /^outputs\[[0-9]+\]\.amount_msat=/ { split($1, a, /[][]/); amt[a[2]] = $2 }
        /^outputs\[[0-9]+\]\.status=/      { split($1, a, /[][]/); st[a[2]] = $2 }
        END { for (i in amt) if (st[i] == "confirmed") s += amt[i]; printf "%d", s / 1000 }')"
    m cln_funds_channel_sat "$(echo "$funds" | sum_sat 'channels\[[0-9]*\]\.our_amount_msat')"
    m cln_channel_capacity_sat "$(echo "$funds" | sum_sat 'channels\[[0-9]*\]\.amount_msat')"
    for s in $STATES; do
      m cln_channels "$(echo "$funds" | grep -c "^channels\[[0-9]*\]\.state=$s$")" ",state=\"$s\""
    done
    m cln_channels_disconnected "$(echo "$funds" | grep -c '^channels\[[0-9]*\]\.connected=false$')"

    pays=$("${CLI[@]}" listpays)
    for s in pending complete failed; do
      m cln_payments "$(echo "$pays" | grep -c "^pays\[[0-9]*\]\.status=$s$")" ",status=\"$s\""
    done
    m cln_invoices_paid "$("${CLI[@]}" listinvoices | grep -c '^invoices\[[0-9]*\]\.status=paid$')"
  else
    m cln_up 0
  fi

  if blocks=$(echo "$RPC_PASSWORD" | bitcoin-cli -regtest -rpcconnect=bitcoind.lightning.svc \
      -rpcuser=lightning -stdinrpcpass getblockcount 2>/dev/null); then
    m cln_chain_blocks "$blocks"
  fi

  m lnwatch_last_run_timestamp_seconds "$(date +%s)"
  mv "$tmp" "$OUT"
  sleep "$INTERVAL"
done
