#!/usr/bin/env bash
# shellcheck disable=SC2329 # the check_* functions are called by name below
###
# Is the practice environment fully up? Read-only. Waits until every check
# passes or TIMEOUT seconds go by (default 1200: a fresh cluster needs about
# fifteen minutes), then prints one PASS / FAIL line per check.
#
#   CONTEXT   kubectl context (default: the one scripts/up.sh writes)
#   TIMEOUT   seconds to wait
#
# Left out on purpose: drill-flux-alert, the Kustomization that a drill keeps
# broken.
###
set -uo pipefail

: "${CLOUDSDK_ACTIVE_CONFIG_NAME:?set the gcloud configuration to use}"
project=$(gcloud config get project 2>/dev/null)
location=$(gcloud container clusters list --filter="name=gke-practice-nonprod" --format='value(location)')
CONTEXT=${CONTEXT:-gke_${project}_${location}_gke-practice-nonprod}
TIMEOUT=${TIMEOUT:-1200}
k() { kubectl --context "$CONTEXT" "$@"; }

# Each check prints what is wrong, or nothing when it passes.
not_ready() { # kind: objects whose Ready condition is not True
  k get "$1" -A -o json | python3 -c '
import json, sys
skip = {"drill-flux-alert"}
for o in json.load(sys.stdin)["items"]:
    m = o["metadata"]
    if m["name"] in skip:
        continue
    ready = [c for c in o.get("status", {}).get("conditions", []) if c["type"] == "Ready"]
    if not ready or ready[0]["status"] != "True":
        print(m["namespace"] + "/" + m["name"])'
}
check_kustomizations() { not_ready kustomizations.kustomize.toolkit.fluxcd.io; }
check_helmreleases()   { not_ready helmreleases.helm.toolkit.fluxcd.io; }
check_externalsecrets() { not_ready externalsecrets.external-secrets.io; }
check_pods() { # every pod Running and ready, or finished
  k get pods -A -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    phase = p["status"].get("phase")
    if phase == "Succeeded":
        continue
    ready = all(c.get("ready") for c in p["status"].get("containerStatuses", []) or [{}])
    if phase != "Running" or not ready:
        print(p["metadata"]["namespace"] + "/" + p["metadata"]["name"] + " " + str(phase))'
}
check_deployments() { # every Deployment and StatefulSet at its replica count
  k get deploy,statefulset -A -o json | python3 -c '
import json, sys
for o in json.load(sys.stdin)["items"]:
    want, have = o["spec"].get("replicas", 1), o["status"].get("readyReplicas", 0)
    if have < want:
        print("%s/%s %d/%d" % (o["metadata"]["namespace"], o["metadata"]["name"], have, want))'
}
check_chains() { # both chains past the 100 blocks run.sh mines, and served by the API
  for ns in esplora esplora-liquid; do
    # shellcheck disable=SC2016 # $API is the container's own variable
    h=$(k -n "$ns" exec esplora-0 -c chainwatch -- sh -c 'curl -fsS -m 5 "$API/blocks/tip/height"' 2>/dev/null)
    case "$h" in ''|*[!0-9]*) echo "$ns: API not answering" ;; *) [ "$h" -ge 100 ] || echo "$ns: height $h" ;; esac
  done
}
check_targets() { # every Prometheus target up
  k get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up==0' 2>/dev/null |
    python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
except Exception:
    print("Prometheus not answering"); sys.exit()
for s in r:
    print(s["metric"].get("job", "?") + " " + s["metric"].get("instance", ""))'
}

checks=(kustomizations helmreleases externalsecrets deployments pods chains targets)
deadline=$((SECONDS + TIMEOUT))
while :; do
  failed=0
  for c in "${checks[@]}"; do
    [ -z "$("check_$c" 2>&1)" ] || failed=1
  done
  [ "$failed" = 0 ] && break
  [ "$SECONDS" -ge "$deadline" ] && break
  echo "waiting... ($((deadline - SECONDS))s left)"
  sleep 30
done

rc=0
for c in "${checks[@]}"; do
  out=$("check_$c" 2>&1)
  if [ -z "$out" ]; then
    printf 'PASS  %s\n' "$c"
  else
    printf 'FAIL  %s\n' "$c"; printf '      %s\n' "${out//$'\n'/$'\n'      }"; rc=1
  fi
done
exit "$rc"
