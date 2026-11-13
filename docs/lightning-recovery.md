# Lightning: getting a node back

What a Core Lightning node here cannot be rebuilt without, where the copies are, and how to get the
money back from each kind of loss. Every step below was run on `cln-bob` on 2026-11-13 (Core
Lightning v26.06.10, regtest), with both of its disks deleted first.

## What is kept, and where

| What | Why | Where |
| --- | --- | --- |
| `hsm_secret` | the root of every key the node has; never changes | `/data`, and Secret Manager `lightning-cln-<node>-hsm-secret` |
| `emergency.recover` | the node's channels and peers; changes when a channel is opened | `/data`, and Secret Manager `lightning-cln-<node>-emergency-recover` |
| the database | the latest state of every channel | `/data` and `/backup`, both written in one transaction |

The two Secret Manager copies are outside the cluster, and nothing in the cluster can read or
replace them (`bootstrap/ci/secrets.tf` gives no one access). They are written by hand:

```bash
export CONTEXT=<kubectl context> CLOUDSDK_ACTIVE_CONFIG_NAME=<gcloud configuration>
scripts/ln-backup.sh alice    # and bob; again after every channel open
```

On a real network the twelve words behind `hsm_secret`
(`lightning-hsmtool getsecret /data/regtest/hsm_secret`) also belong on paper, away from any
computer. Not done here: these are regtest coins.

## Which loss, which way back

| Lost | Way back | Channels | Drilled |
| --- | --- | --- | --- |
| `/data` only | the database on `/backup` is current: copy it and the Secret Manager `hsm_secret` to a new `/data`, start | kept | no |
| `/backup` only | nothing to do: at start lightningd writes the main database over the backup file (its documentation) | kept | no |
| both disks | "Both disks gone" below | closed by the peers; the money comes back on chain | yes |
| `hsm_secret` everywhere | none | everything is lost | |

Never start a node on a database that is not the latest (a disk snapshot, an old copy). It would
publish an old channel state, and the peer may then take the whole channel.

## Both disks gone

1. Stop the node and keep Flux from starting it:

   ```bash
   flux suspend kustomization workloads-lightning
   kubectl -n lightning scale sts cln-bob --replicas=0
   ```

2. An empty `/data` with the two files on it. The StatefulSet makes its claims only together
   with the pod, and lightningd would write a new `hsm_secret` on its first start, so the claim and
   a pod to fill it are made by hand: a PersistentVolumeClaim `data-cln-bob-0` (1Gi, ReadWriteOnce),
   and a pod that mounts it at `/data` with the node's image, `sleep` as its command and the
   security context of the StatefulSet (the namespace is at Pod Security `restricted`). Then:

   ```bash
   for f in hsm_secret emergency.recover; do
     gcloud secrets versions access latest --secret="lightning-cln-bob-$(echo $f | tr '_.' '--')" |
       base64 -d |
       kubectl -n lightning exec -i cln-bob-restore -- \
         sh -c "umask 077; mkdir -p /data/regtest; cat > /data/regtest/$f"
   done
   kubectl -n lightning delete pod cln-bob-restore
   ```

3. Start the node with a rescan of the chain: a new database only looks at blocks from now on,
   and would not see the node's own coins. Add `--rescan=<blocks back>` to the `lightningd`
   command of the StatefulSet (Flux is suspended, so it stays), scale to 1, and check that
   `getinfo` shows the node id from before.

4. Ask the peers to close:

   ```bash
   lightning-cli emergencyrecover
   ```

   Each peer sees a node that has lost its state and closes the channel unilaterally. That
   depends on the peer: it has to be reachable and willing.

5. **Sweep by hand.** On v26.06.10 the node does not claim its own output of such a close: it
   logs `Could not find resolution for output N: did *we* cheat?` and calls the channel resolved,
   and `listfunds` shows nothing. The output is still there and the node's key still owns it:

   ```bash
   scripts/ln-sweep-to-remote.sh bob <peer id> <channels>          # lists what it finds
   scripts/ln-sweep-to-remote.sh bob <peer id> <channels> sweep    # sends it to the node's wallet
   ```

   `<channels>` is how many channel numbers to try: the `#3` of `chan#3` in the logs, which
   counts every channel the node ever had, with any peer.

6. Remove `--rescan`, `flux resume kustomization workloads-lightning`, open channels again, and
   run `scripts/ln-backup.sh`: the channel list has changed.

## What the drill found

- **Copying the `hsm_secret` file back is enough** to get the same node id. Nodes made by
  v25.12 or later keep it in a new format built on twelve words; the file here is about 100
  bytes, not the 32 of older nodes.
- **`emergencyrecover` alone did not bring the channel money back.** The cause is in
  `onchaind` (`handle_their_unilateral`): the restored channel does not know the peer's funding
  key, so the peer's anchor output matches nothing; the search that follows tries other delays for
  the node's own output and leaves the last one it tried in place of the right one, so the node's
  own output, which comes later in the transaction, no longer matches either. The same code is on
  the upstream main branch as of this date. Upstream issue 8880 shows the same message.
- **A rescan does not find everything.** After a peer's unilateral close the node's money stays
  in the close's own output, under a key that needs the peer id and the channel number, which only
  the database has. A new database finds the wallet's ordinary addresses again, not these. The
  sweep script finds them. To have nothing in that state, move the money after such a close
  (`lightning-cli withdraw <address> all`).
- Before the drill bob had 200,000 sat on chain and 100,000 in a channel; after it, 299,600 on
  chain: 400 sat was the fee of the sweep.

So the database on `/backup` is the way back that keeps channels and needs no one's help; the
Secret Manager copies are for when both disks are gone, and that path needs the peers and, on this
version, the manual sweep.
