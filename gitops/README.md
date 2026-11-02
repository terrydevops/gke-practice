# gitops — everything inside the cluster, delivered by Flux

Terraform stops at the cluster boundary. From here on, git is the source of truth and Flux reconciles
the cluster to it. Nothing in this directory has run on a cluster yet: it is checked with
`kustomize build` and `flux build --dry-run` only. In CI, `.github/workflows/gitops.yml` renders every kustomize
directory and checks each object with kubeconform (Kubernetes 1.36, Flux and CRDs-catalog schemas,
unknown fields rejected).

## Layout

```
gitops/
├── clusters/
│   └── nonprod/                # what THIS cluster reconciles (the bootstrap path)
│       ├── flux-system/        # Flux itself + the multi-tenancy lockdown patches;
│       │                       # the two gotk-*.yaml files are filled in by `flux bootstrap`
│       ├── infrastructure.yaml # platform: infra-controllers -> infra-configs
│       ├── tenants.yaml        # one block per tenant (<app>-<env>)
│       └── workloads.yaml      # chain workloads, one block per workload
├── infrastructure/             # PLATFORM-OWNED, applied as cluster-admin
│   ├── controllers/            # operators + CRDs as HelmReleases (CloudNativePG, kube-prometheus-stack,
│   │                           # External Secrets, Reloader, blackbox exporter, Pyrra, Chaos Mesh,
│   │                           # Headlamp)
│   └── configs/                # needs those CRDs or cluster-wide rights (RBAC for humans, alerts,
│                               # SLOs, Grafana and its secret, Flux commit status)
├── tenants/
│   └── base/                   # PLATFORM-OWNED: the fence around one tenant, stamped per tenant
├── apps/                       # TENANT-OWNED, applied as the tenant's own account
│   ├── base/whoami/            # the app once, without an environment
│   └── nonprod/
│       ├── whoami-dev/
│       └── whoami-staging/
├── workloads/                  # PLATFORM-OWNED chain workloads, Pod Security baseline
│   └── esplora/                # the public Esplora image on regtest
└── chaos/                      # fault injection experiments, applied by hand only (never by Flux)
```

Order is explicit: `infra-controllers` → `infra-configs` → each `tenant-*` and each `workloads-*`, every
step waiting for the one before to be healthy (`dependsOn` + `wait: true`).

## Tenant isolation

A tenant is one `<app>-<env>` on the shared cluster. Two layers keep it in its box.

**1. Flux is locked down** (`clusters/nonprod/flux-system/kustomization.yaml`, the patches from the Flux
multi-tenancy guide):

| Flag | Effect |
|---|---|
| `--default-service-account=default` | a Kustomization or HelmRelease that names no account runs as `default`, which has no rights |
| `--no-cross-namespace-refs=true` | an object can only use sources in its own namespace |
| `--no-remote-bases=true` | a `kustomization.yaml` cannot pull manifests from a URL at build time |

Platform objects ask for power by name: `serviceAccountName: kustomize-controller` (or `helm-controller`),
the two accounts Flux binds to cluster-admin.

**2. Each tenant gets a fence** (`tenants/base`, applied by the platform):

| Object | Why the tenant cannot get around it |
|---|---|
| Namespace with Pod Security `restricted` | the tenant has no rights on Namespace objects |
| ResourceQuota + LimitRange | the `admin` role cannot edit quota |
| default-deny NetworkPolicy | the tenant can add allow rules; changing or deleting the baseline is refused at admission |
| ServiceAccount + RoleBinding to `admin`, in its namespace only | nothing cluster-wide, nothing in another namespace |
| no Role or RoleBinding writes | refused at admission, so the tenant cannot hand its rights to anyone else |
| the tenant's Flux Kustomization, with `serviceAccountName` and `targetNamespace` | defined by the platform; the tenant only controls the files under its path |

So a manifest under `apps/nonprod/whoami-dev` that tries to create a ClusterRole, a Namespace, or anything in
`whoami-staging-app` is refused by the API server, because Flux applies it as `whoami-dev`.

The two admission rules are ValidatingAdmissionPolicies in `infrastructure/configs/tenant-guard.yaml`,
evaluated by the API server itself. They refuse everyone except the platform (`kustomize-controller` and
kube-system's controllers), humans included.

Three things this does **not** do:

- Git is one repository. Who may change `tenants/` or another tenant's directory is a matter of merge
  request approval rules (CODEOWNERS), not of Flux.
- Flux aggregates its own CRDs into `admin`, so a tenant may create a Kustomization or HelmRelease in its
  namespace. It gains nothing by it: such an object runs as `default` there and cannot reference a source
  in another namespace.
- A tenant may still add its own NetworkPolicy that allows all ingress (`ingress: [{}]`). Policies add
  up, so that cancels the baseline. Limiting what allow rules may open is left to the policy drill.

## Chain workloads

A third class next to the platform and the tenants, for long-lived, stateful node software such as
Esplora (bitcoind + electrs + nginx in one image). Platform-owned and applied as `kustomize-controller`,
but in their own namespaces:

| | Platform | Chain workloads | Tenants |
|---|---|---|---|
| Example | Flux, monitoring, CloudNativePG | esplora, esplora-liquid, cloudflared | whoami, explorer |
| Applied as | `kustomize-controller` / `helm-controller` | `kustomize-controller` | the tenant's own account |
| Pod Security | per component (monitoring is `privileged`) | `baseline`; warn and audit at `restricted` | `restricted` |
| Ingress | per component | default-deny, then Prometheus to the metrics port only | default-deny, then the tenant's own rules |
| Egress | open | denied: regtest needs no network beyond the pod | open |
| `tenant` label | no | no | yes, so the admission policies apply |

`baseline` because the public Esplora image runs runit as root and nginx on :80. It still refuses
privileged pods, host namespaces and hostPath, so a root container cannot see the node. What root
inside still costs is a container escape: there is no user namespace, so root inside is UID 0 on the
node. Moving to `restricted` means non-root images. Until then: no service account token, no
privilege escalation, no egress.

Not done yet: a tainted node pool of their own (a Terraform change), and anything reachable from outside.

```bash
kubectl -n esplora port-forward svc/esplora 18080:80 14224:4224
# UI http://127.0.0.1:18080/regtest/   metrics http://127.0.0.1:14224/metrics
```

## From Argo CD (eks-practice v2) to Flux (here)

| eks-practice v2 | here |
|---|---|
| Terraform installs Argo CD with a Helm release (the one chart in Terraform) | `flux bootstrap` from a workstation; Terraform has no Helm or Kubernetes provider at all |
| root app-of-apps | the root Kustomization that bootstrap creates for `clusters/nonprod` |
| `addons` ApplicationSet (cluster generator) | `infra-controllers` and `infra-configs` Kustomizations |
| `apps` ApplicationSet (git directory generator) | one `tenant-*` block per tenant in `clusters/nonprod/tenants.yaml`, all stamping `tenants/base` |
| `Application` pointing at a Helm chart | `HelmRepository` + `HelmRelease` (Helm really runs; release history in the cluster) |
| `syncPolicy.automated` with `prune` / `selfHeal` | `prune: true`; self-heal is always on, every `interval` |
| `managedNamespaceMetadata` for Pod Security labels | a plain `Namespace` manifest in the overlay |
| GitOps Bridge: Terraform writes metadata onto the Argo CD cluster Secret | `cluster-vars` ConfigMap + `postBuild.substituteFrom` |
| `platform` AppProject | `serviceAccountName: kustomize-controller` / `helm-controller` on platform objects |
| `apps` AppProject (only `*-app` namespaces) | per-tenant ServiceAccount + RoleBinding, impersonated by Flux, plus the lockdown flags |

## Environment values stay out of git

Two values belong to one real environment: who the cluster admin is, and the proxy-only CIDR. Manifests
refer to them as `${cluster_admin}` and `${proxy_only_cidr}`; Flux fills them in from a ConfigMap that
is created once, from Terraform outputs.

## Bootstrap

The `bootstrap` job of `terraform.yml` runs after every apply: it installs Flux, then waits until
`scripts/check.sh` passes. No GitHub token is involved; `scripts/ci-bootstrap.sh` does inside the
cluster what `flux bootstrap github` would, from what is already in git:

1. **ConfigMap `cluster-vars`**, the values Flux substitutes: from the repository secret
   `CLUSTER_VARS` (lines as in `scripts/cluster-vars.env.example`), plus the proxy-only range read from
   the subnet. Optional `CLUSTER_VIEWER_1..3` are read-only people (see "UI"); an unset slot binds
   nobody.
2. **Secret `flux-system`**: the private half of Flux's read-only deploy key, from Secret Manager
   (`flux-deploy-key`, read by the apply account only), and GitHub's SSH host keys, taken over HTTPS
   from `api.github.com/meta`. The sync uses `ssh://git@ssh.github.com:443/...`, because the VPC
   firewall only lets nodes reach the outside on TCP 443.
3. **`clusters/nonprod/flux-system/`**: the controllers (`gotk-components.yaml`), our lockdown
   patches (`kustomization.yaml`) and the sync (`gotk-sync.yaml`).

From a laptop, for when the job cannot run: `scripts/up.sh` writes the kubeconfig entry (through the
DNS endpoint, pinned to the gcloud account) and runs the same script with the values from the
gitignored `scripts/cluster-vars.env`.

```bash
CLOUDSDK_ACTIVE_CONFIG_NAME=<gcloud configuration> scripts/up.sh
```

**One-time set-up** (already done here; again only to rotate):

```bash
# the deploy key: private half into Secret Manager, public half onto the repository, never on disk for long
d=$(mktemp -d) && ssh-keygen -q -t ed25519 -N '' -C flux-ci -f "$d/k" &&
gcloud --configuration=<config> secrets versions add flux-deploy-key --data-file="$d/k" &&
gh repo deploy-key add "$d/k.pub" --repo <owner>/<repo> --title flux-ci && rm -rf "$d"
# the values
gh secret set CLUSTER_VARS --repo <owner>/<repo> < scripts/cluster-vars.env
```

To rotate the key, run the first command, delete the old key on GitHub, and run the bootstrap
(an apply, or `scripts/up.sh`).

**Upgrading Flux:** `flux install --export > clusters/nonprod/flux-system/gotk-components.yaml` with
the new CLI, through a pull request; Flux then upgrades itself.

After that, a change is a merge to `main`; nobody runs `kubectl apply`.

## Monitoring

kube-prometheus-stack in `monitoring` (`infrastructure/controllers/kube-prometheus-stack.yaml`). Grafana is a
release of its own in the configs layer (`infrastructure/configs/grafana.yaml`), because its password
comes from a Secret that External Secrets creates there.

- **No route from outside** until drill 9. Open the UIs with port-forward:

  ```bash
  kubectl -n monitoring port-forward svc/grafana 3000:80
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093
  kubectl -n monitoring port-forward svc/pyrra 9099
  ```

- **Grafana login:** user `admin`. The password is in Google Secret Manager (`grafana-admin-password`),
  in neither git nor Terraform state. `bootstrap/ci/secrets.tf` creates the secret and lets exactly one
  Kubernetes service account read it (`monitoring/grafana-secrets`, through Workload Identity); External
  Secrets copies it into the `grafana-admin` Secret.

  ```bash
  # read it
  gcloud --configuration=<config> secrets versions access latest --secret=grafana-admin-password
  # set it (first time) or rotate it: a new random value, never shown or written to disk
  openssl rand -base64 24 | tr -d '\n' |
    gcloud --configuration=<config> secrets versions add grafana-admin-password --data-file=-
  # copy it now instead of within the hour; Reloader then restarts Grafana
  kubectl -n monitoring annotate externalsecret grafana-admin force-sync="$(date +%s)" --overwrite
  ```

  The secret is in `bootstrap/`, so it survives a teardown: a rebuilt cluster gets the same password.

- **Not scraped:** scheduler, controller-manager, etcd (GKE runs the control plane) and kube-proxy
  (Dataplane V2 has none). Their rules are off too, so `Watchdog` is the only alert that fires on a
  healthy cluster.
- **Our alerts:** `infrastructure/configs/alerts.yaml`. No receiver yet; look in Alertmanager.
- **Flux itself:** `infrastructure/configs/flux-monitoring.yaml`. kube-state-metrics exports every
  Kustomization, HelmRelease and source as `gotk_resource_info` with its Ready status; one PodMonitor
  scrapes the four controllers. Alerts: `FluxObjectNotReady` (10 min), `FluxObjectStuck`,
  `FluxObjectSuspended` (info, a day), `FluxControllerDown`, `FluxReconcileErrors`. Dashboards
  "Flux Cluster Stats" and "Flux Control Plane", from fluxcd/flux2-monitoring-example.
- **Events:** `infrastructure/controllers/logging.yaml`. Alloy watches Kubernetes events in every
  namespace and pushes them to Loki (one pod, 5Gi, 7 days); the API server itself keeps an hour.
  Dashboard "Kubernetes events": FailedScheduling, autoscaler scale-up decisions, BackOff, evictions,
  node events, each with its message. Explore → Loki, `{job="loki.source.kubernetes_events"} | logfmt`.
- **Chain logs:** the same Alloy reads the `esplora` container of both chain pods through the API
  server, labelled by process from svlogd's prefix: `{job="chain-pods", namespace="esplora-liquid",
  component="node"}` (also `electrs`, `tor`, `nginx`, ...). Tip-height poll lines and tor bootstrap
  retries are dropped. A logs row at the bottom of "Esplora chains".
- **Processes in the chain containers:** the esplora image runs its services under runit in one
  container, so cAdvisor sees only their sum and a service restarted by runit never shows as a
  container restart. `process-exporter` (a DaemonSet in `monitoring`, hostPID, read-only `/proc`;
  `infrastructure/configs/process-exporter.yaml`) counts each process; recording rules
  `esplora_process:*` tie them to namespace and pod. Row "Processes inside the esplora container"
  in "Esplora chains": CPU, memory, running count, uptime per service. `EsploraProcessDown` fires
  when the chain node, electrs or nginx stays at 0 processes for 2 minutes.
- **SLOs:** `infrastructure/slo/slo-whoami.yaml`. The blackbox exporter probes each whoami Service
  from inside the cluster every 15s; Pyrra turns the results into availability (99%) and latency
  (95% under 250ms) objectives over 7 days, one budget per environment, with burn-rate alerts
  (`ErrorBudgetBurn`). See them in the Pyrra UI or the "Pyrra" dashboards in Grafana. A tenant is
  probed only if its NetworkPolicy lets the prober in (`apps/base/whoami/networkpolicy.yaml`).
  The Flux Kustomization `infra-slo` applies them only after the probed apps are Ready, so a
  rebuild does not start with a burnt budget. While one of those apps is down, `infra-slo` reports
  "dependency not ready" and holds back changes to the SLO files; the probes already running keep
  recording.
- **Storage:** Prometheus 10Gi (7 days), Alertmanager 1Gi. Both disks are deleted with the release.

## UI

Headlamp in `headlamp` (`infrastructure/controllers/headlamp.yaml`), with the Flux plugin: each
Kustomization and HelmRelease, what it applied, and whether it is healthy. Not exposed; it holds no
rights of its own, so everyone signs in with their own token and sees what their RBAC allows.

```bash
kubectl -n headlamp port-forward svc/headlamp 4466:80    # then http://localhost:4466
gcloud --configuration=<config> auth print-access-token  # paste as the token; valid one hour
```

Read-only access for someone else, in two layers, with no e-mail in git:

1. **Reach the cluster (IAM):** add `user:<e-mail>` to `cluster_users` (the `TF_VAR_CLUSTER_USERS`
   secret and the local tfvars) and apply `bootstrap/ci`.
2. **See inside (RBAC):** put the e-mail in a free viewer slot, which binds `view` on the cluster and
   port-forward to Headlamp only (`infrastructure/configs/rbac.yaml`):

   ```bash
   kubectl -n flux-system patch configmap cluster-vars --type merge \
     -p '{"data":{"cluster_viewer_1":"<e-mail>"}}'
   flux reconcile kustomization infra-configs -n flux-system
   ```

`view` shows workloads, pod logs, events and Flux objects; not Secrets, exec, or port-forward
anywhere but Headlamp. To take access away, remove the key and the IAM member again.

## Chaos

Chaos Mesh in `chaos-mesh` (`infrastructure/controllers/chaos-mesh.yaml`); the experiments are in
`chaos/`, applied by hand only. See `chaos/README.md` for running one.

- **Reach:** only pods in namespaces annotated `chaos-mesh.org/inject: enabled`, set by `tenants/base`
  on tenant namespaces. Tenants have no rights on the chaos kinds.
- **Privileged:** chaos-daemon runs on every node with host PID, privileged, and the containerd
  socket; that is how it enters a pod to add tc rules or stress processes.
- **Dashboard:** not exposed. It asks for a token and acts with that token's rights; on GKE that can
  be the caller's own Google access token.

  ```bash
  kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333
  gcloud --configuration=<config> auth print-access-token   # paste as the token
  ```

## Commit status

Flux marks every commit on `main` on GitHub with one status per Kustomization (success or failure),
so the commit list shows whether a change reached the cluster. PRs are rebased onto `main`, so the
status is on the `main` commit, not on the PR. Set up in `infrastructure/configs/flux-commit-status.yaml`.

Flux signs in as a GitHub App. Its credentials are in Google Secret Manager
(`flux-github-commit-status`, created by `bootstrap/ci/secrets.tf`), in neither git nor state; External
Secrets copies them into the `flux-system/flux-github` Secret.

One-time setup:

1. GitHub, Settings, Developer settings, GitHub Apps, New GitHub App. No webhook. Repository
   permissions: **Commit statuses: Read and write**, nothing else. Only on this account.
2. Generate a private key (a `.pem` download), then Install App on this repository only. Note the
   App ID (the app's page) and the installation ID (the number at the end of the installation's URL).
3. Store all three as one JSON object, piped so nothing is shown or written, then delete the `.pem`:

   ```bash
   python3 -c 'import json, sys; print(json.dumps({"githubAppID": sys.argv[1],
     "githubAppInstallationID": sys.argv[2], "githubAppPrivateKey": open(sys.argv[3]).read()}), end="")' \
     <app-id> <installation-id> <key.pem> |
     gcloud --configuration=<config> secrets versions add flux-github-commit-status --data-file=-
   ```

To rotate the key, generate a new one on the app, add a version the same way, delete the old key on
GitHub, and force a copy:
`kubectl -n flux-system annotate externalsecret flux-github force-sync="$(date +%s)" --overwrite`.

## Tear down and rebuild

The environment is meant to be torn down when nobody practises and rebuilt on demand, as often as
needed. Data does not survive: Prometheus and Loki history, the chains (regtest mines its first 100
blocks again) and Pyrra's 7-day windows start from empty. Secrets do: they live in Secret Manager
(`bootstrap/ci/secrets.tf`), and External Secrets copies them in again.

1. **Tear down:** Actions > terraform > Run workflow on `main`, `action` = `destroy`, `confirm` = the
   cluster name. It deletes everything in `envs/nonprod` (cluster, node pool, VPC, NAT and its
   addresses, firewall rules, node service account), then the disks the PersistentVolumes left
   behind: GKE does not delete those with the cluster, and they would bill on. The job fails if any
   disk of the cluster is still there. What stays is `bootstrap/` (state bucket, CI identity, who may
   connect, the secrets).
2. **Rebuild:** Run workflow on `main` with `action` = `apply`. The `bootstrap` job then installs Flux
   and waits until every Kustomization, HelmRelease and ExternalSecret is Ready, every workload is at
   its replica count, both chains answer and every Prometheus target is up; its summary has a PASS or
   FAIL line for each. A green run means the environment can be used.

A chaos experiment or a load test still running does not block the destroy; the cluster goes with it.
Anything added later that creates cloud resources of its own (a load balancer, a NEG) must be removed
before the destroy, or the VPC cannot be deleted. Check that nothing is left:

```bash
for r in firewall-rules disks addresses forwarding-rules network-endpoint-groups target-pools; do
  gcloud --configuration=<config> compute $r list --format='value(name)'
done
```

Only the `default-allow-*` rules of the project's `default` VPC should be listed.

## Gaps

- `flux bootstrap` writes the repository URL into `flux-system/gotk-sync.yaml`, in git.
- whoami has no route from outside yet (a Gateway on the proxy-only subnet), and no VPA object: vertical
  Pod autoscaling is not switched on in the cluster module.
- The PostgreSQL cluster, its WAL archive to GCS and the restore drill are the next layer.
