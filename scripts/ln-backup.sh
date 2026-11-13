#!/usr/bin/env bash
###
# Copy what a Core Lightning node cannot be rebuilt without to Secret Manager,
# outside the cluster (docs/lightning-recovery.md):
#
#   hsm_secret          the root of every key; never changes
#   emergency.recover   the node's channels; changes when a channel is opened,
#                       so run this again after every open
#
#   CONTEXT                       kubectl context of the cluster (required)
#   CLOUDSDK_ACTIVE_CONFIG_NAME   gcloud configuration to use (required)
#
# Each file is stored base64-encoded in lightning-cln-<node>-hsm-secret and
# lightning-cln-<node>-emergency-recover (bootstrap/ci/secrets.tf). It goes
# from the pod to gcloud through a pipe: not to this machine's disk, not to
# the terminal. A new version is added only when the file has changed, and
# what was stored is read back and compared by checksum.
###
set -euo pipefail

: "${CONTEXT:?set CONTEXT to the kubectl context of the cluster}"
: "${CLOUDSDK_ACTIVE_CONFIG_NAME:?set the gcloud configuration to use}"
node=${1:-}
case "$node" in alice | bob) ;; *)
  echo "usage: CONTEXT=... CLOUDSDK_ACTIVE_CONFIG_NAME=... $0 alice|bob" >&2
  exit 2
  ;;
esac

k() { kubectl --context "$CONTEXT" -n lightning "$@"; }
in_pod() { k exec "cln-$node-0" -c lightningd -- "$@"; }
sum() { shasum -a 256 | cut -d' ' -f1; }
# Checksum of the file that the latest version of a secret holds; empty when
# the secret has no version yet.
stored() { gcloud secrets versions access latest --secret="$1" 2>/dev/null | base64 -d | sum; }
empty=$(printf '' | sum)

for file in hsm_secret emergency.recover; do
  secret=lightning-cln-$node-$(echo "$file" | tr '_.' '--')
  path=/data/regtest/$file
  if ! in_pod test -f "$path"; then
    echo "$file: not on the node (no channel opened yet?), skipped"
    continue
  fi
  here=$(in_pod sha256sum "$path" | cut -d' ' -f1)
  if [ "$(stored "$secret")" = "$here" ]; then
    echo "$file: unchanged, $secret is up to date"
    continue
  fi
  in_pod base64 -w0 "$path" | gcloud secrets versions add "$secret" --data-file=- --no-user-output-enabled
  there=$(stored "$secret")
  if [ "$there" != "$here" ] || [ "$there" = "$empty" ]; then
    echo "$file: what $secret now holds does not match the node" >&2
    exit 1
  fi
  echo "$file: stored in $secret, checksum matches the node"
done
