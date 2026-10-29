#!/bin/sh
# Chain metrics for Prometheus, in its text format, for one regtest chain.
# Runs next to the node in the same pod: the CLI finds the RPC port and the
# cookie under /data by itself, and the REST API is the pod's own nginx.
# Written to a file that the metrics container serves; rewritten every
# $INTERVAL seconds, atomically.
#
# Env: CHAIN (label), CLI (the node's CLI with -conf and -datadir),
#      API (REST base URL), NATIVE_ASSET (Liquid only: label in dumpassetlabels)
set -u
OUT=/metrics/chain.prom
INTERVAL=${INTERVAL:-15}

num() { sed -n "s/.*\"$1\": *\([-0-9.e+]*\).*/\1/p" | head -n 1; }

while :; do
  tmp=$OUT.tmp
  : > "$tmp"
  m() { echo "$1{chain=\"$CHAIN\"} $2" >> "$tmp"; }

  if info=$($CLI getblockchaininfo 2>/dev/null); then
    m chain_rpc_up 1
    m chain_blocks "$(echo "$info" | num blocks)"
    m chain_headers "$(echo "$info" | num headers)"
    m chain_verification_progress "$(echo "$info" | num verificationprogress)"
    m chain_size_on_disk_bytes "$(echo "$info" | num size_on_disk)"
    case "$(echo "$info" | grep '"initialblockdownload"')" in
      *true*) m chain_initial_block_download 1 ;;
      *) m chain_initial_block_download 0 ;;
    esac
    tip=$($CLI getbestblockhash)
    m chain_tip_timestamp_seconds "$($CLI getblockheader "$tip" | num time)"
    m chain_peers "$($CLI getconnectioncount)"
    pool=$($CLI getmempoolinfo)
    m chain_mempool_transactions "$(echo "$pool" | num size)"
    m chain_mempool_bytes "$(echo "$pool" | num bytes)"
    m chain_mempool_usage_bytes "$(echo "$pool" | num usage)"
    m chain_mempool_max_bytes "$(echo "$pool" | num maxmempool)"

    # Largest explicit output in the tip block, from the REST API (first page
    # of 25 transactions). Blinded Liquid outputs carry no value and are not
    # counted: confidential amounts cannot be inspected.
    largest=$(curl -fsS -m 5 "$API/block/$tip/txs" 2>/dev/null \
      | grep -o '"value":[0-9]*' | cut -d: -f2 | sort -n | tail -n 1)
    m chain_largest_output_tip_block_sats "${largest:-0}"

    if [ -n "${NATIVE_ASSET:-}" ]; then
      asset=$($CLI dumpassetlabels | sed -n "s/.*\"$NATIVE_ASSET\": *\"\([0-9a-f]*\)\".*/\1/p")
      stats=$(curl -fsS -m 5 "$API/asset/$asset" 2>/dev/null \
        | sed 's/.*"chain_stats":{\([^}]*\)}.*/\1/')
      for f in issued_amount burned_amount issuance_count tx_count; do
        v=$(echo "$stats" | grep -o "\"$f\":[0-9]*" | cut -d: -f2)
        [ -n "$v" ] && m "chain_native_asset_$f" "$v"
      done
    fi
  else
    m chain_rpc_up 0
  fi

  if h=$(curl -fsS -m 5 "$API/blocks/tip/height" 2>/dev/null); then
    m chain_api_up 1
    m chain_api_tip_height "$h"
  else
    m chain_api_up 0
  fi

  m chainwatch_last_run_timestamp_seconds "$(date +%s)"
  mv "$tmp" "$OUT"
  sleep "$INTERVAL"
done
