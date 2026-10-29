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
│   │                           # External Secrets, Reloader, blackbox exporter, Pyrra)
│   └── configs/                # needs those CRDs or cluster-wide rights (RBAC for humans, alerts,
│                               # SLOs, Grafana and its secret, Flux commit status)
├── tenants/
│   └── base/                   # PLATFORM-OWNED: the fence around one tenant, stamped per tenant
├── apps/                       # TENANT-OWNED, applied as the tenant's own account
│   ├── base/whoami/            # the app once, without an environment
│   └── nonprod/
│       ├── whoami-dev/
│       └── whoami-staging/
└── workloads/                  # PLATFORM-OWNED chain workloads, Pod Security baseline
    └── esplora/                # the public Esplora image on regtest
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
| Example | Flux, monitoring, CloudNativePG | esplora | whoami |
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

Needs a cluster, and a user who is project owner (cluster-admin through IAM) for this one step.
No gcloud configuration is active by default, so the account is named explicitly.

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=<gcloud configuration>   # this shell only
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)   # for terraform output

# 1. kubeconfig through the DNS endpoint, then pin it to the account: the auth
#    plugin otherwise follows whichever configuration is active, and its token
#    cache, which can hold another account's token.
$(terraform -chdir=envs/nonprod output -raw get_credentials)
kubectl config set-credentials "$(kubectl config view --minify -o jsonpath='{.users[0].name}')" \
  --exec-arg="--account=$(gcloud config get account)"

# 2. the values Flux substitutes, before anything reconciles
kubectl create namespace flux-system
kubectl -n flux-system create configmap cluster-vars \
  --from-literal=cluster_admin="<google account e-mail>" \
  --from-literal=proxy_only_cidr="$(terraform -chdir=envs/nonprod output -raw proxy_only_cidr)"

# 3. Flux installs itself, fills in the two gotk-*.yaml files under
#    gitops/clusters/nonprod/flux-system/ and commits them. The kustomization.yaml
#    there (the lockdown patches) is ours and is applied from the first start.
export GITHUB_TOKEN=<personal access token; used by this command only>
flux bootstrap github \
  --owner=<github user> --repository=<repo> --personal \
  --branch=main --path=gitops/clusters/nonprod \
  --ssh-hostname=ssh.github.com:443
```

Bootstrap creates a read-only deploy key on this one repository and keeps its private half in the
cluster. `--ssh-hostname` points the sync at GitHub's SSH endpoint on port 443, because the VPC firewall
only lets nodes reach the outside on TCP 443: plain SSH to github.com:22 would be dropped. The sync URL
becomes `ssh://git@ssh.github.com:443/<owner>/<repo>`.

Not `--token-auth`: it also uses port 443, but it stores the personal access token itself in the
cluster, and that token can act as you on every repository it reaches. A deploy key reaches only this
one.

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
- **SLOs:** `infrastructure/configs/slo-whoami.yaml`. The blackbox exporter probes each whoami Service
  from inside the cluster every 15s; Pyrra turns the results into availability (99%) and latency
  (95% under 250ms) objectives over 7 days, one budget per environment, with burn-rate alerts
  (`ErrorBudgetBurn`). See them in the Pyrra UI or the "Pyrra" dashboards in Grafana. A tenant is
  probed only if its NetworkPolicy lets the prober in (`apps/base/whoami/networkpolicy.yaml`).
- **Storage:** Prometheus 10Gi (7 days), Alertmanager 1Gi. Both disks are deleted with the release.

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

Tear down: Actions > terraform > Run workflow on `main`, `action` = `destroy`, `confirm` = the cluster
name. It deletes everything in `envs/nonprod`: cluster, node pool, VPC, NAT and its addresses, firewall
rules, node service account. What stays is `bootstrap/` (state bucket, CI identity, who may connect,
the Grafana password).

Deleting the cluster does not delete the disks behind its PersistentVolumes. The only ones today are
monitoring's, so remove that release first; its disks go with it (`whenDeleted: Delete`):

```bash
flux suspend kustomization infra-controllers   # or Flux puts the release back
kubectl -n flux-system delete helmrelease kube-prometheus-stack
kubectl get pv                                 # wait until none is left
```

Anything added later that creates cloud resources (a load balancer, another volume) is removed the same
way, or the destroy leaves it behind or fails on it. Check that nothing is left:

```bash
for r in firewall-rules disks addresses forwarding-rules network-endpoint-groups target-pools; do
  gcloud --configuration=<config> compute $r list --format='value(name)'
done
```

Only the `default-allow-*` rules of the project's `default` VPC should be listed.

Rebuild: Run workflow on `main` with `action` = `apply`, then the three Bootstrap steps above. Flux
installs monitoring again with empty disks. The
deploy key of the old cluster stays on GitHub with nothing left to use it; bootstrap adds a new one.

## Gaps

- `flux bootstrap` writes the repository URL into `flux-system/gotk-sync.yaml`, in git.
- whoami has no route from outside yet (a Gateway on the proxy-only subnet), and no VPA object: vertical
  Pod autoscaling is not switched on in the cluster module.
- The PostgreSQL cluster, its WAL archive to GCS and the restore drill are the next layer.
