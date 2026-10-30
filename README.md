# gke-practice

The GKE counterpart of `eks-practice` v2, built to learn where GKE differs. Same rule:

> **Terraform = GCP only. GitOps (Flux) = everything in-cluster.**

**Status: bootstrap applied, environment only planned.** The state bucket and the CI identity
(`bootstrap/`) exist; all three roots keep their state in the bucket. `envs/nonprod` (network and
cluster, 24 resources) has been planned but never applied.

## Layout

```
gke-practice/
├── bootstrap/          # applied once, by a human, in this order
│   ├── state/          # GCS bucket for Terraform state (and, once created, its own state)
│   └── ci/             # GitHub Actions Workload Identity Federation: plan SA (read-only, any
│                       # branch), apply SA (main only), access to the state bucket; and who
│                       # may connect to the cluster (IAM), which must outlive a teardown
├── modules/
│   ├── network/
│   │   ├── main.tf     # VPC and its subnets: nodes (+ pod / service ranges), proxy-only
│   │   ├── nat.tf      # Cloud NAT on reserved static IPs, node subnet only
│   │   └── firewall.tf # VPC baseline: logged default-deny for ingress AND egress
│   └── cluster/
│       ├── main.tf      # private VPC-native GKE Standard, DNS-only control plane endpoint
│       ├── node_pool.tf # one autoscaled pool (Spot in nonprod)
│       ├── iam.tf       # the nodes' least-privilege service account
│       └── firewall.tf  # ingress to the nodes, targeted by that service account
├── envs/
│   └── nonprod/        # one shared cluster (dev + staging as namespaces)
│       ├── main.tf     # APIs, network, cluster
│       └── backend.tf  # GCS backend; the bucket name is passed at init (docs/state.md)
├── gitops/             # everything in-cluster, reconciled by Flux (see gitops/README.md)
│   ├── clusters/nonprod/   # bootstrap path: Flux lockdown, platform, one block per tenant
│   ├── infrastructure/     # platform-owned: CloudNativePG operator (HelmRelease), RBAC
│   ├── tenants/base/       # platform-owned: the fence stamped around each tenant
│   └── apps/               # tenant-owned: whoami base + dev / staging
├── docs/state.md       # where state and locks live, how to switch them on, how to recover
└── .github/workflows/
    ├── terraform.yml   # validate -> plan (any branch) -> apply (main only, started by hand)
    └── gitops.yml      # render + schema check of gitops/
```

Still to add: a PostgreSQL cluster on CloudNativePG with WAL archiving to GCS and a restore drill,
kube-prometheus-stack with one alert, a route to whoami from outside.

## Configuration

No project ID, account or other environment-specific value is committed. Each root reads them from a
local `terraform.tfvars` (git-ignored; copy `terraform.tfvars.example`), and the pipeline reads them
from repository secrets listed at the top of `.github/workflows/terraform.yml`.

## Plan

No gcloud configuration is active by default, so every command names its account. Terraform does
not read application-default credentials; it gets a token from a named gcloud configuration:

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud --configuration=<config> auth print-access-token)  # ~1 hour
cd envs/nonprod
cp terraform.tfvars.example terraform.tfvars   # then fill in your own values
terraform init -backend-config="bucket=<state bucket>"   # the output of bootstrap/state
terraform plan
```

Apply and destroy run in CI (Run workflow on `main`); see `gitops/README.md` for the teardown and the
rebuild.

## EKS → GKE map

| Concept | eks-practice v2 | gke-practice |
|---|---|---|
| VPC and subnets | regional VPC, public + private subnets per AZ | global VPC, regional subnets that each span all zones |
| What makes a node private | subnet route table (NAT, not IGW) | the node has no external IP |
| Outbound for private nodes | NAT gateway | Cloud Router + Cloud NAT, one per region |
| Pod IPs | vpc-cni with prefix delegation | VPC-native alias IPs from a secondary range |
| NetworkPolicy | vpc-cni `enableNetworkPolicy` | Dataplane V2, built in |
| Security groups / NACLs | SGs per ENI, NACLs per subnet | VPC firewall rules, targeted by service account or tag |
| Who may reach the API server | public endpoint + access entries | DNS-based endpoint, authorised by IAM; both IP endpoints off |
| Human access to the cluster | EKS access entries → access policies | a custom IAM role that only allows connecting, then Kubernetes RBAC from git |
| Pod → cloud identity | Pod Identity / IRSA | Workload Identity |
| Stop pods borrowing node credentials | IMDSv2, hop limit 1 | GKE metadata server (`GKE_METADATA`) |
| Node identity | node IAM role | dedicated node service account, not the Compute default |
| Nodes | managed node group + Karpenter | node pools + cluster autoscaler (or Autopilot) |
| Node OS | Bottlerocket | Container-Optimized OS |
| Base addons (DNS, CNI, CSI) | EKS managed addons in Terraform | built into GKE, nothing to declare |
| Upgrades | you bump `cluster_version` | release channel inside a maintenance window |
| Cluster DNS | CoreDNS managed addon | Cloud DNS for GKE + NodeLocal DNSCache |
| Step zero in a new account | nothing | enable each API (`google_project_service`) |
| CI identity | IAM OIDC provider + role trust policy | workload identity pool + provider, service account impersonation |
| Terraform state | S3 + DynamoDB lock | GCS bucket (locks itself) |
| GitOps engine | Argo CD | Flux |

## Policies in place

What the cluster enforces today, and why. Paths are under `gitops/` unless they start elsewhere.

### Resources and scheduling

| Policy | Where | Purpose |
|---|---|---|
| ResourceQuota, tenants | `tenants/base/quota.yaml` | Caps each tenant's CPU, memory and pods, so one tenant cannot starve the others |
| ResourceQuota, chain workloads | `workloads/components/limits/`, `workloads/cloudflared/` | A ceiling for esplora, esplora-liquid and cloudflared; a runaway autoscaler stops here |
| LimitRange | same two places | Default requests and limits for a container that sets none |
| PriorityClass `platform-critical` | `clusters/nonprod/flux-system/priority.yaml` | Flux, External Secrets, monitoring and Headlamp are the last to be preempted |
| PriorityClass `chain-node` | same | Chain nodes and cloudflared rank below the platform, above tenant apps |
| No platform priority for tenants | `tenants/base/quota.yaml` | A `pods: "0"` quota scoped to both classes: a tenant pod cannot claim them |
| PodDisruptionBudget | whoami, explorer, cloudflared | At most one replica evicted at a time on a drain or a scale-down |
| No PDB on a single replica | esplora StatefulSets (header) | A budget on one replica blocks drains; the short outage is accepted and documented |
| topologySpreadConstraints | whoami, explorer, cloudflared | Replicas on different nodes (hard for staging, explorer, cloudflared), so one node loss cannot take them all |
| Rolling update `maxSurge: 1`, `maxUnavailable: 0` | whoami, explorer, cloudflared | The new pod starts first; a rollout never drops below the replica count |
| Node pool surge upgrade | `modules/cluster/node_pool.tf` | A node upgrade adds one node before it removes one |
| Cluster autoscaler | `modules/cluster/node_pool.tf` | Adds and removes nodes for pending pods; measured about 70s up, about 12 minutes down |
| Spot nodes | `modules/cluster/node_pool.tf` | Cheaper nodes, at the cost of reclaims; the rules above are what make reclaims survivable |
| Right-sized requests | Flux patch, kube-prometheus-stack values | Requests set from measured use, so nodes pack better |

### Security

| Policy | Where | Purpose |
|---|---|---|
| Pod Security Admission | namespace labels | `restricted` for tenants, Headlamp and cloudflared; `baseline` for the chains; `privileged` only where node agents run (monitoring, chaos-mesh) |
| Default-deny NetworkPolicy | tenants, esplora, cloudflared | All ingress denied, then only named sources and ports let in, by label |
| Flux multi-tenancy lockdown | `clusters/nonprod/flux-system/kustomization.yaml` | No cross-namespace references, no remote bases, and a default service account with no rights |
| Tenant RBAC | `tenants/base/` | Tenants are admins of their namespace but cannot edit their own quota or LimitRange |
| Secrets from Secret Manager | External Secrets, Workload Identity | No secret in git; the cluster reads them from Secret Manager, one reader per namespace |
| Images pinned by digest | every workload | An image cannot change under a tag; an upgrade is a reviewed change |
| Container securityContext | every workload | Non-root where the image allows, all capabilities dropped, read-only root file system, seccomp |
| No service account token | workloads that never call the API | `automountServiceAccountToken: false` |
| Headlamp viewer slots | `cluster-vars` | A fixed number of people get read-only `view` access |
| No default cloud account | local practice, CI | Every gcloud call names its configuration; Terraform runs on an access token, not ADC |

### Observability

| Policy | Where | Purpose |
|---|---|---|
| SLOs (Pyrra) | `infrastructure/configs/slo-*.yaml` | Targets and error budgets for availability, latency and, for Esplora, data freshness |
| Blackbox probes | same | Each service probed every 15s from inside the cluster, the way a user calls it |
| Burn-rate alerts | generated by Pyrra | Alert on how fast the budget burns, not on a single failure |
| Chain alerts | `workloads/esplora*/monitoring.yaml` | electrs stalled, index behind, node RPC or API down |
| Alert delivery | Alertmanager to ntfy | Alerts reach a phone |
| Flux commit status | GitHub App | Each commit on GitHub shows whether the cluster applied it |
| Bounded retention | kube-prometheus-stack values | 7 days or 8GB, whichever comes first; old data goes before the disk fills |

### CI and GitOps

| Policy | Where | Purpose |
|---|---|---|
| Required checks | `.github/workflows/` | Render and schema check of `gitops/`, Terraform validate and plan, lint and secret scan; merge only when green |
| Repository hygiene | `.github/scripts/hygiene.sh` | No non-English text and no environment-specific values in the repository |
| Flux substitution check | `.github/scripts/check-flux-substitution.py` | Catches a broken `${...}` before Flux does |
| Plan on PR, apply by hand | `.github/workflows/terraform.yml` | Every PR shows its plan; apply and destroy are started by hand on `main` |
| Weekly security scan and drift check | `security.yml`, `drift.yml` | Workflow and config scans, then a plan against the real project, every Monday |
| Dependabot | `.github/dependabot.yml` | PRs for dependency updates |
| Chaos experiments and load tests | `chaos/` | Run by hand, never by Flux, and removed after |

### Not done yet

| Policy | Plan |
|---|---|
| Taints, tolerations, nodeSelector | An on-demand `system` pool, and a taint on the Spot pool |
| Pod anti-affinity | Esplora read replicas kept off the primary's node |
| HorizontalPodAutoscaler | Esplora read replicas, scaled on CPU |
| More than one zone | The node pool across two zones; the zone spread rules are written but have one zone to work with |
| Preemption test | Once the `system` pool exists |
| explorer to esplora connection limit | The image's nginx allows 10 connections per client IP, and every explorer user arrives from the explorer pod's IP |
| Baseline load test run | The test is in `chaos/load/`; not run yet |
