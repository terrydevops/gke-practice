#!/usr/bin/env bash
###
# Install Flux on a freshly applied cluster, without a GitHub token. What
# `flux bootstrap github` does inside the cluster, from files already in git:
#
#   1. ConfigMap cluster-vars: the values Flux substitutes, from $CLUSTER_VARS
#      (lines of KEY=value, as scripts/cluster-vars.env.example)
#   2. Secret flux-system: the deploy key from Secret Manager (flux-deploy-key)
#      and GitHub's SSH host keys, taken over HTTPS from api.github.com/meta
#   3. gitops/clusters/nonprod/flux-system: controllers, lockdown patches, sync
#
# Run by the bootstrap job in terraform.yml after every apply, and by
# scripts/up.sh from a laptop. Safe to run again: every step converges.
#
#   CONTEXT       kubectl context of the cluster
#   PROJECT       GCP project; REGION its region
#   CLUSTER_VARS  the values, as text
###
set -euo pipefail

: "${CONTEXT:?}" "${PROJECT:?}" "${REGION:?}" "${CLUSTER_VARS:?}"
cluster=gke-practice-nonprod
root=$(cd "$(dirname "$0")/.." && pwd)
k() { kubectl --context "$CONTEXT" "$@"; }

echo "1/3 cluster-vars"
args=()
while IFS= read -r line; do
  line=${line%%#*}                          # comments, whole-line or trailing
  line=${line%"${line##*[![:space:]]}"}       # trailing blanks
  [ -n "$line" ] || continue
  key=${line%%=*} value=${line#*=}
  case "$key" in
    CLUSTER_ADMIN) args+=(--from-literal="cluster_admin=$value") ;;
    CLUSTER_VIEWER_[123]) [ -z "$value" ] || args+=(--from-literal="cluster_viewer_${key##*_}=$value") ;;
    *) echo "unknown key in CLUSTER_VARS: $key" >&2; exit 1 ;;
  esac
done <<<"$CLUSTER_VARS"
[ "${#args[@]}" -gt 0 ] || { echo "CLUSTER_ADMIN missing from CLUSTER_VARS" >&2; exit 1; }
proxy_only_cidr=$(gcloud compute networks subnets describe "$cluster-proxy-only" \
  --project "$PROJECT" --region "$REGION" --format='value(ipCidrRange)')
args+=(--from-literal="proxy_only_cidr=$proxy_only_cidr")
k create namespace flux-system --dry-run=client -o yaml | k apply -f - >/dev/null
k -n flux-system create configmap cluster-vars "${args[@]}" --dry-run=client -o yaml |
  k apply -f - >/dev/null

echo "2/3 Secret flux-system (deploy key, GitHub host keys)"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
gcloud secrets versions access latest --secret=flux-deploy-key --project "$PROJECT" >"$dir/identity"
# Port 443: the VPC only lets nodes out on 443 (gitops/README.md, "Bootstrap").
curl -fsS https://api.github.com/meta |
  python3 -c 'import json, sys; [print("[ssh.github.com]:443 " + k) for k in json.load(sys.stdin)["ssh_keys"]]' \
  >"$dir/known_hosts"
[ -s "$dir/known_hosts" ] || { echo "no SSH host keys from api.github.com/meta" >&2; exit 1; }
k -n flux-system create secret generic flux-system \
  --from-file=identity="$dir/identity" --from-file=known_hosts="$dir/known_hosts" \
  --dry-run=client -o yaml | k apply -f - >/dev/null

echo "3/3 Flux"
# The first pass installs the CRDs and cannot yet create the objects that use
# them; the second, once the CRDs are established, does.
k apply --server-side -k "$root/gitops/clusters/nonprod/flux-system" >/dev/null 2>&1 || true
k wait --for=condition=Established crd -l app.kubernetes.io/part-of=flux --timeout=120s >/dev/null
k apply --server-side -k "$root/gitops/clusters/nonprod/flux-system" >/dev/null
k -n flux-system rollout status deployment/source-controller --timeout=300s >/dev/null
k -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=300s
echo "Flux is syncing from git"
