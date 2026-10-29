# Exercises: what was drilled on EKS, and the order to drill it here

`eks-practice` (109 commits, 2026-06-22 to 2026-07-21) worked through the exercises below. This file
lists them, says where each one stands in this repo, and sets the order for the ones still open.

Status as of 2026-10-25, with the nonprod cluster running. Status words:

- **run** — applied to the cluster and checked there
- **in git** — written and reconciled, but the behaviour itself was not tested
- **open** — not written
- **n/a** — the problem does not exist on GKE, or GKE solves it differently

## The exercises

### 1. Terraform layers and state

| Exercise on EKS | What it taught | Here |
|---|---|---|
| v1: one state holding AWS and in-cluster resources | the structural mistake behind most later problems; ended in a rebuild | avoided from the start |
| v2 in three layers: network → cluster → gitops | the first two are cloud-only, so a feature branch can plan safely | open: network and cluster share one root |
| State moved to S3, bootstrap under its own key | | run (GCS, three prefixes) |
| dev and staging share one nonprod cluster | namespaces instead of a second control plane and NAT | run |
| prod in its own account, code only | | open |
| One command to build, one to tear down | teardown must wait for the load balancer to go, or the certificate stays in use | run (drill 2): Run workflow with `action=destroy`; nothing is left behind while the cluster creates no cloud resources of its own (no load balancer yet) |

### 2. CI/CD

| Exercise on EKS | What it taught | Here |
|---|---|---|
| CI OIDC, no long-lived keys | plan role read-only on any branch, apply role on protected refs | run: GitHub Actions; apply bound to `main`, since GitHub tokens carry no protected-ref claim |
| `exit 255` when plan talked to the cluster | the CLI subprocess could not see the web identity variables | n/a: Terraform never connects to the cluster |
| Closing the CI hole | a plan role usable from any branch was cluster admin, so any branch could read every Secret | avoided by design |
| Dropping the cloud CLI from the job | the provider's own web identity support is enough | run |
| Run only when Terraform paths change | | run |
| New branch seen as "everything changed" | compare with main | run |

### 3. Cluster access

| Exercise on EKS | What it taught | Here |
|---|---|---|
| Pin the cluster admin access entry | it followed "whoever ran terraform" and flipped between laptop and CI | n/a: different mechanism, next row |
| A least-privilege admin role | almost nothing on the cloud side, admin inside | in git: the connect-only role exists, but an owner account cannot show that it works |
| Lockout while swapping the access entry | delete-then-create met eventual consistency; use additive changes | n/a |

### 4. GitOps

| Exercise on EKS (Argo CD) | What it taught | Here (Flux) |
|---|---|---|
| Install the engine, deploy whoami | | run |
| Platform and tenant AppProjects | tenants only reach `*-app` namespaces | run: one service account per tenant plus the lockdown flags; checked with `auth can-i` |
| ApplicationSet and app-of-apps | a directory that exists is deployed | run (nested Kustomizations) |
| GitOps Bridge | Terraform hands metadata to the cluster | run (`cluster-vars` ConfigMap, written by hand at bootstrap) |
| Trailing slash in the repo URL | the AppProject glob does not cross `/` | n/a |
| app-of-apps deadlock | a CRD and its first object in one sync | n/a: `dependsOn` orders them |

### 5. Nodes and elasticity

| Exercise on EKS | What it taught | Here |
|---|---|---|
| Prefix delegation, maxPods 110 | 17 pods per node by default; DaemonSets got stuck | n/a |
| Two nodes across zones | one node could not hold both Karpenter replicas | open: one node, one zone |
| Karpenter: controller, CRDs, NodePool | cloud side in Terraform, controller in GitOps | in git: node pool autoscaling 1 to 3, never triggered |
| IMDSv2 hop limit 1 | pods cannot borrow node credentials | in git (`GKE_METADATA`), not attacked |
| Load balancer controller crash loop | hop limit 1 blocked its discovery | n/a |
| Node termination handler | only for the managed node group | open: the only pool is Spot (reclaims handled by GKE), no drain drill |
| Bottlerocket | | n/a: Container-Optimized OS |

### 6. Workload hardening

| Exercise on EKS | What it taught | Here |
|---|---|---|
| PodDisruptionBudget | | in git, no drain yet |
| NetworkPolicy, default deny | the load balancer subnet must be let in | run; deleting or editing the platform's default-deny is refused at admission (drill 1). Gap: a tenant's own allow-all policy still cancels it |
| ResourceQuota and LimitRange | | in git; the tenant cannot create a quota (checked), edit and delete not asked |
| VPA in recommend-only mode | requests were lowered from its numbers | open: VPA is off on the cluster |
| Topology spread | | in git; means little on one node |
| Readiness and liveness probes | | run (pods are Ready through them) |
| Non-root, read-only root filesystem | v1 ran as root | run (admitted under `restricted`) |

### 7. Policy

| Exercise on EKS | What it taught | Here |
|---|---|---|
| Pod Security Admission labels | | run (`restricted`, enforce); a root pod applied as the tenant is refused (drill 1) |
| Kyverno policies | scoped to `*-app`; image names in full | open |
| Kyverno and permanent OutOfSync | fields injected by the webhook; solved with server-side diff | open |

### 8. Ingress, TLS, DNS

| Exercise on EKS | What it taught | Here |
|---|---|---|
| ALB with an ACM certificate | | open: whoami has no route from outside; Gateway API is switched on |
| Load balancer controller and external-dns | | open |
| Cross-account DNS role | session tags need `sts:TagSession` | open, and no domain is available yet |
| Grafana and Argo CD UIs exposed | ingress limited to one source IP | open |

### 9. Monitoring and alerting

| Exercise on EKS | What it taught | Here |
|---|---|---|
| metrics-server | | n/a: built in |
| kube-prometheus-stack | | done (drill 3): a Flux HelmRelease, chart pinned |
| ServiceMonitor and dashboard for Karpenter | a scrape annotation is not monitoring | open |
| Alertmanager node alerts | | open |
| Silencing managed control plane alerts | etcd and friends are not exposed | done (drill 3): their scrapes and rules are off; only `Watchdog` fires |
| Fixed Grafana password | a random one caused a restart loop | done (drill 4): set in Secret Manager; Reloader restarts Grafana when it changes |
| Prometheus storage and Slack route | | storage done (drill 3): 10Gi for 7 days, Alertmanager 1Gi; no receiver yet |
| External Secrets for the Grafana password | the secret is in neither git nor state | done (drill 4): ESO with direct Workload Identity Federation, one KSA trusted, tenants get no ESO rights |

### 10. SLO and chaos

| Exercise on EKS | What it taught | Here |
|---|---|---|
| Blackbox probe of whoami | | done (drill 5): in-cluster Probe every 15s; the tenant's NetworkPolicy admits the prober |
| Pyrra availability and latency SLOs | multi-window burn-rate alerts | done (drill 5): one objective per environment, since Pyrra makes no dashboard rules for a grouped one; fast burn fired 144s after whoami-dev went to zero |
| SLOs as a reusable Helm chart | | open |
| Chaos Mesh, four experiments | pod kill, network delay, CPU stress, weekly schedule | open |
| Experiments in git, synced by hand | fault injection must be deliberate | open |

### Planned on EKS, never done

Graviton and spot pools, an OPA/conftest gate, backup and restore (Velero), progressive delivery
(Argo Rollouts), long-term metrics (Thanos or Mimir), a production cluster.

## Drill order

Ordered by dependency first, then by how much each step exercises: every step leaves something the
next one uses. Each has a check that says it is done.

| # | Drill | From group | Done when | Adds to the bill |
|---|---|---|---|---|
| 1 | **Close the fence.** (done 2026-10-25) Stop a tenant from removing the platform's default-deny policy and from handing its rights to someone else, while it can still manage its own allow rules; try to run a root pod in a tenant namespace | 4, 6, 7 | as the tenant's account: deleting `default-deny-ingress` and creating a RoleBinding are refused, whoami's own policy still reconciles; the root pod is refused by admission | nothing |
| 2 | **Tear down and rebuild.** (done 2026-10-25) A destroy path (manual pipeline job), then the whole bootstrap again from the written steps | 1 | cluster gone with no leftover firewall rules, disks or addresses; rebuilt and all Kustomizations Ready from the README alone | nothing; saves money every night after |
| 3 | **Monitoring.** (done 2026-10-26) kube-prometheus-stack through Flux, persistent storage, the control plane false alarms silenced, one alert of our own that fires and resolves | 9 | the alert is seen firing in Alertmanager after its cause is created, and gone after the cause is removed | two disks (10Gi + 1Gi), about USD 1.5 a month; one node was enough (memory 73%) |
| 4 | **Secrets.** (done 2026-10-29) External Secrets with Secret Manager through Workload Identity, for the Grafana password | 9 | the password is in neither git nor Terraform state; rotating it in Secret Manager reaches the pod | cents |
| 5 | **SLO.** (done 2026-10-29) Blackbox probe of whoami inside the cluster, Pyrra availability and latency objectives | 10 | scaling whoami to zero burns the budget and the fast-burn alert fires | nothing |
| 6 | **Chaos.** Chaos Mesh with pod kill, network delay, CPU stress; experiments in git, started by hand | 10 | each experiment shows on the SLO dashboard and the service recovers without help | nothing |
| 7 | **Elasticity.** Force a scale-out, drain a node against the PDB, add a second zone, then split into an on-demand pool for system pods and the Spot pool | 5, 6 | pending pods bring a node; the drain never takes whoami below its budget; replicas land in both zones | a node or two for the length of the drill |
| 8 | **PostgreSQL.** A CloudNativePG cluster, WAL archive to GCS through Workload Identity, restore to a point in time | new | a row written before the "accident" is back after the restore, and the time it took is written down | disks and a bucket |
| 9 | **Route from outside.** Static address and certificate in Terraform, Gateway and HTTPRoute in Flux | 8 | whoami answers from the internet; teardown (drill 2) still leaves nothing behind | a load balancer and an address (price not looked up) |
| 10 | **Policy.** Kyverno scoped to tenant namespaces; VPA switched on in Terraform, recommend-only | 6, 7 | a bad manifest is refused with a readable message; Flux stays Ready with the webhook in place | nothing |

Why this order:

- **1 before everything**: it is a known hole, costs nothing, and later drills add tenants' objects.
  Closed with two ValidatingAdmissionPolicies (`gitops/infrastructure/configs/tenant-guard.yaml`): the
  tenant keeps its NetworkPolicy rights, but default-deny and all Role / RoleBinding writes are refused.
- **2 early**: without a destroy path the cluster bills around the clock. It is also the only proof
  that the bootstrap steps are complete, and it gets harder with every layer added.
- **3 to 6 in a row**: each needs the one before. The SLO has nothing to read without Prometheus, and
  a chaos experiment with no SLO shows nothing.
- **5 uses an in-cluster probe**, so the SLO work does not wait for a public route.
- **9 late**: it is the first thing that makes the cluster create cloud resources of its own, which is
  what makes teardown order matter. Drill 2 is then run again.

Not checked yet, to confirm before the drill that needs it:

- whether Chaos Mesh's network and stress experiments work on Container-Optimized OS with
  Dataplane V2 (drill 6);
- a certificate for drill 9 needs a domain name, and there is none yet.

Left for later: splitting network and cluster into separate roots, a production environment, a second
non-owner account to prove the connect-only role, Flux Operator in place of the manual bootstrap.
