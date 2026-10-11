# gitops — everything inside the cluster, delivered by Flux

Terraform stops at the cluster boundary. From here on, git is the source of truth and Flux reconciles
the cluster to it. Nothing in this directory has run on a cluster yet: it is checked with
`kustomize build` and `flux build --dry-run` only.

## Layout

```
gitops/
├── clusters/
│   └── nonprod/                # what THIS cluster reconciles (the bootstrap path)
│       ├── flux-system/        # Flux itself + the multi-tenancy lockdown patches;
│       │                       # the two gotk-*.yaml files are filled in by `flux bootstrap`
│       ├── infrastructure.yaml # platform: infra-controllers -> infra-configs
│       └── tenants.yaml        # one block per tenant (<app>-<env>)
├── infrastructure/             # PLATFORM-OWNED, applied as cluster-admin
│   ├── controllers/            # operators + CRDs as HelmReleases (CloudNativePG)
│   └── configs/                # needs those CRDs or cluster-wide rights (RBAC for humans)
├── tenants/
│   └── base/                   # PLATFORM-OWNED: the fence around one tenant, stamped per tenant
└── apps/                       # TENANT-OWNED, applied as the tenant's own account
    ├── base/whoami/            # the app once, without an environment
    └── nonprod/
        ├── whoami-dev/
        └── whoami-staging/
```

Order is explicit: `infra-controllers` → `infra-configs` → each `tenant-*`, every step waiting for the one
before to be healthy (`dependsOn` + `wait: true`).

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
| default-deny NetworkPolicy | the tenant can add allow rules; the baseline is re-applied if removed |
| ServiceAccount + RoleBinding to `admin`, in its namespace only | nothing cluster-wide, nothing in another namespace |
| the tenant's Flux Kustomization, with `serviceAccountName` and `targetNamespace` | defined by the platform; the tenant only controls the files under its path |

So a manifest under `apps/nonprod/whoami-dev` that tries to create a ClusterRole, a Namespace, or anything in
`whoami-staging-app` is refused by the API server, because Flux applies it as `whoami-dev`.

Two things this does **not** do:

- Git is one repository. Who may change `tenants/` or another tenant's directory is a matter of merge
  request approval rules (CODEOWNERS), not of Flux.
- Flux aggregates its own CRDs into `admin`, so a tenant may create a Kustomization or HelmRelease in its
  namespace. It gains nothing by it: such an object runs as `default` there and cannot reference a source
  in another namespace.

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

## Bootstrap (not run yet)

Needs a cluster, and a user who is project owner (cluster-admin through IAM) for this one step.

```bash
# 1. kubeconfig through the DNS endpoint
$(terraform -chdir=envs/nonprod output -raw get_credentials)

# 2. the values Flux substitutes, before anything reconciles
kubectl create namespace flux-system
kubectl -n flux-system create configmap cluster-vars \
  --from-literal=cluster_admin="<google account e-mail>" \
  --from-literal=proxy_only_cidr="$(terraform -chdir=envs/nonprod output -raw proxy_only_cidr)"

# 3. Flux installs itself, fills in the two gotk-*.yaml files under
#    gitops/clusters/nonprod/flux-system/ and commits them. The kustomization.yaml
#    there (the lockdown patches) is ours and is applied from the first start.
export GITLAB_TOKEN=<personal access token with api scope; used by this command only>
flux bootstrap gitlab \
  --owner=<gitlab namespace> --repository=<repo> --personal \
  --branch=main --path=gitops/clusters/nonprod \
  --deploy-token-auth
```

`--deploy-token-auth` makes Flux fetch over HTTPS with a project deploy token that bootstrap creates for
it. Two reasons not to use the other modes:

- the default is an SSH deploy key, and the VPC firewall only lets nodes reach the outside on TCP 443,
  so SSH to the Git host would be dropped;
- `--token-auth` also uses HTTPS, but it stores the personal access token itself in the cluster. A
  deploy token is scoped to this one project, so what sits in the cluster cannot act as you elsewhere.

After that, a change is a merge to `main`; nobody runs `kubectl apply`.

## Gaps

- No CI check for this directory. A `kustomize build` / `flux build` job would catch a broken manifest
  before Flux does.
- `flux bootstrap` writes the repository URL into `flux-system/gotk-sync.yaml`, in git.
- whoami has no route from outside yet (a Gateway on the proxy-only subnet), and no VPA object: vertical
  Pod autoscaling is not switched on in the cluster module.
- The PostgreSQL cluster, its WAL archive to GCS and the restore drill are the next layer.
