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
│       ├── node_pool.tf # one autoscaled pool
│       ├── iam.tf       # the nodes' least-privilege service account
│       └── firewall.tf  # ingress to the nodes, targeted by that service account
├── envs/
│   └── nonprod/        # one shared cluster (dev + staging as namespaces)
│       ├── main.tf     # APIs, network, cluster
│       ├── access.tf   # hands cluster access over to bootstrap/ci (removed blocks)
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
