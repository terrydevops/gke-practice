#!/bin/sh
# A regtest chain makes no blocks on its own. This one mines a block every
# $INTERVAL seconds so the chain moves like a real one, and the block-stall
# alert means something. To drill a stall, pause it:
#   kubectl -n <ns> exec <pod> -c esplora -- touch /data/miner-paused
# and remove the file to resume. Coinbase goes to an anyone-can-spend script.
set -u
DESC='raw(51)#8lvh9jxk'
until $CLI getblockcount >/dev/null 2>&1; do sleep 5; done
while :; do
  if [ -e /data/miner-paused ]; then
    echo "paused"
  else
    $CLI generatetodescriptor 1 "$DESC" >/dev/null && echo "mined $($CLI getblockcount)"
  fi
  sleep "$INTERVAL"
done
