# CI standard

One set of CI rules for this repo and for eth-docker-practice. It combines:

- what each repo already did well: the identity design here, and the security gate there;
- [OpenSSF Scorecard](https://github.com/ossf/scorecard/blob/main/docs/checks.md);
- GitHub's *Security hardening for GitHub Actions*;
- HashiCorp's *Running Terraform in automation*;
- the [zizmor](https://docs.zizmor.sh/audits/) audits.

A repo follows **Baseline**, plus every profile that matches what it contains. A rule that cannot be met
is listed under "Accepted gaps" with the reason, not dropped silently.

The IDs are used in workflow comments, so a reader can trace a step back to its rule.

## Baseline (every repo)

| ID | Rule | Why | Source |
|---|---|---|---|
| B1 | Top-level `permissions: contents: read`; any write is granted per job | a compromised step gets the least possible token | Scorecard Token-Permissions |
| B2 | Actions pinned to a commit sha with a version comment; downloads checked by sha256; images by digest | tags move, shas do not | Scorecard Pinned-Dependencies |
| B3 | Dependabot keeps those pins current, with a cooldown | a pin that never moves collects CVEs; the cooldown gives a bad release time to be pulled | Scorecard Dependency-Update-Tool |
| B4 | `actions/checkout` with `persist-credentials: false` | otherwise the token stays in `.git/config` for every later step | zizmor `artipacked` |
| B5 | actionlint and zizmor on every push | broken expressions, template injection, dangerous triggers | Scorecard Dangerous-Workflow |
| B6 | Untrusted values (inputs, PR titles, branch names) reach `run:` only through `env:` | `${{ }}` inside `run:` is shell injection | GitHub hardening guide |
| B7 | yamllint `--strict` for all YAML; shellcheck for all shell scripts | cheap, and it catches real mistakes | eth-docker-practice |
| B8 | Secret scan of the tree | a leaked key is found before it is pushed again | eth-docker-practice |
| B9 | Hygiene script: English only. Whether AI attribution is allowed is a per-repo switch | each repo states its own rule; one script enforces it | eth-docker-practice |
| B10 | Checks: superseded runs are cancelled. Apply and destroy: serialised, **never** cancelled | stale checks waste minutes; a cancelled apply leaves a half-applied state | GitHub docs |
| B11 | Weekly scheduled run | pins do not change, advisories do | eth-docker-practice |
| B12 | Runner image pinned (`ubuntu-24.04`, not `ubuntu-latest`); `timeout-minutes` on every job | an image change breaks builds silently; a hung job runs for 6 h | common practice |
| B13 | The default branch is protected: no force-push, no deletion, required checks green before merge | the gate the other rules rely on | Scorecard Branch-Protection |
| B14 | Public repos: `LICENSE` and `SECURITY.md` | how to report a problem | Scorecard Security-Policy |

## IaC profile (Terraform)

| ID | Rule | Why | Source |
|---|---|---|---|
| T1 | `fmt -check` and `validate` for every root; `.terraform.lock.hcl` committed; Terraform version pinned | the same providers on a laptop and in CI | HashiCorp |
| T2 | tflint with the cloud provider's ruleset | invalid machine types, deprecated arguments, unused declarations | common practice |
| T3 | IaC misconfiguration scan; every accepted finding has a reason and an expiry | the same ignore-file pattern eth uses for image CVEs | common practice |
| T4 | OIDC / workload identity, no stored keys; the plan identity is read-only; the apply identity is bound to the protected branch **in cloud IAM** | the gate cannot be removed by editing a workflow | GitHub hardening guide |
| T5 | The plan is readable without opening logs: a redacted job summary | review is the point of plan | common practice (Atlantis: PR comments) |
| T6 | Apply runs exactly the reviewed plan: the saved plan file from the same run | what was reviewed is what runs | HashiCorp |
| T7 | Applies are serialised: a concurrency group plus the state lock | two applies corrupt state | HashiCorp |
| T8 | Weekly drift check: `plan -detailed-exitcode` as the read-only identity | console edits show up within a week | common practice |
| T9 | Destructive runs are manual, main-only, with a typed confirmation | a misclick does not delete a cluster | this repo |
| T10 | No environment-specific value committed; values that appear in logs are masked | the repo could be made public | this repo |

## GitOps profile (Kubernetes manifests)

| ID | Rule | Why |
|---|---|---|
| K1 | Render every directory the way the controller does (`kustomize build`); a failed build fails the job | an empty stream looks valid |
| K2 | kubeconform `-strict` against the **running cluster's** version, plus the installed controllers' CRD schemas | an unknown field fails in CI instead of being dropped by the API server |
| K3 | Admission policies are tested in CI (from drill 10) | a policy change is reviewed like code |

## Containers profile (images and compose)

| ID | Rule | Why |
|---|---|---|
| C1 | Every image reference pinned by digest, checked by a script | B2 for compose files |
| C2 | Image CVE scan: CRITICAL, ignore unfixed; every accepted finding has a reason and an expiry | the weekly run fails once an expiry passes |
| C3 | Config renders (`docker compose config`); domain tests run (for example promtool rules and tests) | catches broken config before it is started |

## This repo

Profiles: Baseline, IaC, GitOps.

| ID | Where |
|---|---|
| B1, B2, B6 | every workflow |
| B3 | `.github/dependabot.yml`: github-actions and the three Terraform roots, 7-day cooldown |
| B4, B10, B12 | every workflow. Pushes cancel each other's checks; a Run workflow has its own group, and `terraform-apply` serialises apply and destroy |
| B5, B7, B8, B9 | `security.yml`: `lint` and `secrets` jobs. B9 is `.github/scripts/hygiene.sh`, attribution allowed |
| B11 | `security.yml` (Monday 04:23 UTC) and `drift.yml` (Monday 04:41 UTC) |
| T1, T4, T7, T9, T10 | `terraform.yml` and `bootstrap/ci` |
| T2, T3 | `security.yml`, `iac` job: `.tflint.hcl`, trivy config with `.trivyignore.yaml` |
| T5 | `.github/scripts/plan-summary.sh`, used by plan, destroy and drift |
| T6 | `terraform.yml`: the plan job uploads `tfplan` (Run workflow with `action=apply` only, kept one day); apply runs that file |
| T8 | `drift.yml`. An empty state (torn down) passes with a notice |
| K1, K2 | `gitops.yml` |

### Accepted gaps

| ID | Gap | Why accepted | What still holds |
|---|---|---|---|
| B13 | `main` is not protected | a private repo on GitHub's free plan cannot be protected (the API answers "Upgrade to GitHub Pro or make this repository public") | only `refs/heads/main` can impersonate the apply account (T4), so a branch cannot apply |
| T6 | the plan file is an artifact | it can hold sensitive values in clear text, readable by anyone who can read the repo | the repo is private and the artifact is kept one day. If the repo goes public, encrypt it or plan again in apply |
| K3 | no policy tests yet | there is no Kyverno until drill 10 | the two admission policies were tested by hand in drill 1 |

### Accepted scan findings

- **Where they live:** `.trivyignore.yaml`. Each entry has a reason and an `expired_at` date; once that
  date passes, the weekly run fails until the entry is renewed or fixed.
- **Not scanned:** `gotk-components.yaml`, Flux's own install, generated by `flux bootstrap`. Its
  controllers need the wide ClusterRoles the scan reports. The repo controls them only through Flux's
  version.
