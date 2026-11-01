#!/usr/bin/env bash
###
# Bootstrap a freshly applied cluster: the three hand steps of "Bootstrap" in
# gitops/README.md, as one command. Run it after Actions > terraform > apply.
#
#   CLOUDSDK_ACTIVE_CONFIG_NAME  gcloud configuration of a project owner
#   GITHUB_TOKEN                 for flux bootstrap only; never stored or printed
#   scripts/cluster-vars.env     the values Flux substitutes (gitignored; copy
#                                cluster-vars.env.example)
#
# Safe to run again: every step converges. The kubeconfig entry is added or
# refreshed, but the current kubectl context is left as it was.
###
set -euo pipefail

: "${CLOUDSDK_ACTIVE_CONFIG_NAME:?set the gcloud configuration to use}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN for flux bootstrap}"

here=$(cd "$(dirname "$0")" && pwd)
vars="$here/cluster-vars.env"
[ -f "$vars" ] || { echo "missing $vars (copy cluster-vars.env.example)" >&2; exit 1; }
# shellcheck source=/dev/null  # gitignored, values only
. "$vars"
: "${CLUSTER_ADMIN:?CLUSTER_ADMIN is empty in $vars}"
: "${GITHUB_OWNER:?GITHUB_OWNER is empty in $vars}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is empty in $vars}"

cluster=gke-practice-nonprod
project=$(gcloud config get project 2>/dev/null)
account=$(gcloud config get account 2>/dev/null)
location=$(gcloud container clusters list --filter="name=$cluster" --format='value(location)')
[ -n "$location" ] || { echo "no cluster $cluster in $project; run the apply first" >&2; exit 1; }
region=${location%-*}
ctx="gke_${project}_${location}_${cluster}"

echo "1/3 kubeconfig for $cluster ($location), through the DNS endpoint"
previous=$(kubectl config current-context 2>/dev/null || true)
gcloud container clusters get-credentials "$cluster" --location "$location" --dns-endpoint
# Pin the auth plugin to this account: it otherwise follows whichever gcloud
# configuration is active, and its token cache can hold another account's token.
kubectl config set-credentials "$ctx" --exec-arg="--account=$account" >/dev/null
if [ -n "$previous" ]; then kubectl config use-context "$previous" >/dev/null; fi

echo "2/3 cluster-vars, before anything reconciles"
proxy_only_cidr=$(gcloud compute networks subnets describe "$cluster-proxy-only" \
  --region "$region" --format='value(ipCidrRange)')
args=(--from-literal=cluster_admin="$CLUSTER_ADMIN" --from-literal=proxy_only_cidr="$proxy_only_cidr")
for i in 1 2 3; do
  v="CLUSTER_VIEWER_$i"
  if [ -n "${!v:-}" ]; then args+=(--from-literal="cluster_viewer_$i=${!v}"); fi
done
kubectl --context "$ctx" create namespace flux-system --dry-run=client -o yaml |
  kubectl --context "$ctx" apply -f - >/dev/null
kubectl --context "$ctx" -n flux-system create configmap cluster-vars "${args[@]}" \
  --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null

echo "3/3 flux bootstrap (replaces the old cluster's deploy key, same title)"
flux bootstrap github --context "$ctx" \
  --owner="$GITHUB_OWNER" --repository="$GITHUB_REPOSITORY" --personal \
  --branch=main --path=gitops/clusters/nonprod \
  --ssh-hostname=ssh.github.com:443

echo "done; now: scripts/check.sh"
