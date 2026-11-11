#!/bin/sh
# A regtest chain makes no blocks on its own. This one mines a block every
# $INTERVAL seconds so the chain moves like a real one, and the block-stall
# alert means something. To drill a stall, pause it:
#   kubectl -n <ns> exec <pod> -c esplora -- touch /data/miner-paused
# and remove the file to resume. Coinbase goes to an anyone-can-spend script.
set -u
# PID 1 of its container: a signal without a handler is ignored there, so
# without this trap the pod waits out its whole grace period to stop. The
# sleep runs in the background so that the trap fires at once, not after it.
trap 'exit 0' TERM INT
DESC='raw(51)#8lvh9jxk'
until $CLI getblockcount >/dev/null 2>&1; do sleep 5 & wait $!; done
while :; do
  if [ -e /data/miner-paused ]; then
    echo "paused"
  else
    $CLI generatetodescriptor 1 "$DESC" >/dev/null && echo "mined $($CLI getblockcount)"
  fi
  sleep "$INTERVAL" &
  wait $!
done
