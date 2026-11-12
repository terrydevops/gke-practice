#!/bin/bash
# Core Lightning node metrics for Prometheus, in its text format. Runs next to
# lightningd in the same pod and talks to it through the RPC socket under
# /data. The chain height comes from bitcoind's RPC, so a node that stops
# following the chain shows. Written to a file that the metrics container
# serves; rewritten every $INTERVAL seconds, atomically.
#
# Env: NODE (label), RPC_PASSWORD (bitcoind), INTERVAL (default 15)
set -u
# PID 1 of its container: a signal without a handler is ignored there, so
# without this trap the pod waits out its whole grace period to stop. The
# sleep runs in the background so that the trap fires at once, not after it.
trap 'exit 0' TERM INT
OUT=/metrics/ln.prom
INTERVAL=${INTERVAL:-15}
CLI=(lightning-cli --lightning-dir=/data -F)
STATES="CHANNELD_AWAITING_LOCKIN CHANNELD_NORMAL CHANNELD_SHUTTING_DOWN CLOSINGD_SIGEXCHANGE CLOSINGD_COMPLETE AWAITING_UNILATERAL FUNDING_SPEND_SEEN ONCHAIN"

# One field of `lightning-cli -F` output (key=value lines), first match.
field() { sed -n "s/^$1=//p" | head -n 1; }
# Sum of every value of a field across a list, msat, as satoshis.
# %.0f, not %d: mawk (this image's awk) caps %d at 2^31-1, about 21 BTC.
sum_sat() { sed -n "s/^$1=//p" | awk '{ s += $1 } END { printf "%.0f", int(s / 1000) }'; }

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
        END { for (i in amt) if (st[i] == "confirmed") s += amt[i]; printf "%.0f", int(s / 1000) }')"
    m cln_funds_channel_sat "$(echo "$funds" | sum_sat 'channels\[[0-9]*\]\.our_amount_msat')"
    m cln_channel_capacity_sat "$(echo "$funds" | sum_sat 'channels\[[0-9]*\]\.amount_msat')"
    for s in $STATES; do
      m cln_channels "$(echo "$funds" | grep -c "^channels\[[0-9]*\]\.state=$s$")" ",state=\"$s\""
    done
    m cln_channels_disconnected "$(echo "$funds" | grep -c '^channels\[[0-9]*\]\.connected=false$')"

    # Pending HTLCs, force closes and each open channel's usable balance,
    # from the channels' own list. A close that went through
    # CLOSINGD_COMPLETE was agreed by both sides; one that reached the chain
    # without it was unilateral. An HTLC's expiry is a block height.
    "${CLI[@]}" listpeerchannels | awk -F= -v node="$NODE" \
        -v tip="$(echo "$info" | field blockheight)" '
      function chan() { split($1, a, /[][]/); return a[2] }
      function htlc() { split($1, a, /[][]/); return a[2] "/" a[4] }
      /^channels\[[0-9]+\]\.htlcs\[[0-9]+\]\.direction=/   { dir[htlc()] = $2 }
      /^channels\[[0-9]+\]\.htlcs\[[0-9]+\]\.amount_msat=/ { amt[htlc()] = $2 }
      /^channels\[[0-9]+\]\.htlcs\[[0-9]+\]\.expiry=/      { due[htlc()] = $2 }
      /^channels\[[0-9]+\]\.state=/                        { st[chan()] = $2 }
      /^channels\[[0-9]+\]\.short_channel_id=/             { scid[chan()] = $2 }
      /^channels\[[0-9]+\]\.spendable_msat=/               { spend[chan()] = $2 }
      /^channels\[[0-9]+\]\.receivable_msat=/              { recv[chan()] = $2 }
      /^channels\[[0-9]+\]\.state_changes\[[0-9]+\]\.new_state=CLOSINGD_COMPLETE$/ { mutual[chan()] = 1 }
      END {
        n["in"] = n["out"] = 0
        for (k in dir) {
          n[dir[k]]++
          msat[dir[k]] += amt[k]
          d = due[k] + 0
          if (!some || d < first) { first = d; some = 1 }
        }
        for (d in n) {
          printf "cln_htlcs{node=\"%s\",direction=\"%s\"} %d\n", node, d, n[d]
          printf "cln_htlc_pending_sat{node=\"%s\",direction=\"%s\"} %.0f\n", node, d, int(msat[d] / 1000)
        }
        # Blocks until the first pending HTLC expires; absent when there is none.
        if (some) printf "cln_htlc_expiry_blocks{node=\"%s\"} %d\n", node, first - tip
        for (c in st) {
          if (st[c] ~ /^(AWAITING_UNILATERAL|FUNDING_SPEND_SEEN|ONCHAIN)$/ && !(c in mutual)) forced++
          if (st[c] == "CHANNELD_NORMAL" && c in scid) {
            printf "cln_channel_spendable_sat{node=\"%s\",short_channel_id=\"%s\"} %.0f\n", node, scid[c], int(spend[c] / 1000)
            printf "cln_channel_receivable_sat{node=\"%s\",short_channel_id=\"%s\"} %.0f\n", node, scid[c], int(recv[c] / 1000)
          }
        }
        printf "cln_channels_force_closed{node=\"%s\"} %d\n", node, forced
      }' >> "$tmp"

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
  sleep "$INTERVAL" &
  wait $!
done
