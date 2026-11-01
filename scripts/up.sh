#!/usr/bin/env bash
###
# The CI bootstrap job, from a laptop: for when the job cannot run, or to
# bootstrap again by hand. Writes the kubeconfig entry, then runs
# scripts/ci-bootstrap.sh with the values from scripts/cluster-vars.env.
#
#   CLOUDSDK_ACTIVE_CONFIG_NAME  gcloud configuration of a project owner
#   scripts/cluster-vars.env     gitignored; copy cluster-vars.env.example
#
# The current kubectl context is left as it was.
###
set -euo pipefail

: "${CLOUDSDK_ACTIVE_CONFIG_NAME:?set the gcloud configuration to use}"
here=$(cd "$(dirname "$0")" && pwd)
vars="$here/cluster-vars.env"
[ -f "$vars" ] || { echo "missing $vars (copy cluster-vars.env.example)" >&2; exit 1; }

cluster=gke-practice-nonprod
project=$(gcloud config get project 2>/dev/null)
account=$(gcloud config get account 2>/dev/null)
location=$(gcloud container clusters list --filter="name=$cluster" --format='value(location)')
[ -n "$location" ] || { echo "no cluster $cluster in $project; run the apply first" >&2; exit 1; }
ctx="gke_${project}_${location}_${cluster}"

echo "kubeconfig for $cluster ($location), through the DNS endpoint"
previous=$(kubectl config current-context 2>/dev/null || true)
gcloud container clusters get-credentials "$cluster" --location "$location" --dns-endpoint
# Pin the auth plugin to this account: it otherwise follows whichever gcloud
# configuration is active, and its token cache can hold another account's token.
kubectl config set-credentials "$ctx" --exec-arg="--account=$account" >/dev/null
if [ -n "$previous" ]; then kubectl config use-context "$previous" >/dev/null; fi

CONTEXT=$ctx PROJECT=$project REGION=${location%-*} CLUSTER_VARS=$(cat "$vars") \
  "$here/ci-bootstrap.sh"
echo "now: scripts/check.sh"
