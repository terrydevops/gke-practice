###
# Bootstrap, step 2: CI/CD identity (GCP only) — Workload Identity Federation for GitHub Actions
# plus the two service accounts the workflows impersonate. No service-account keys:
# a job proves who it is with a short-lived GitHub OIDC token.
# Counterpart of eks-practice/v2/ci.
#
#   plan SA  : any run in this GitHub repository may impersonate it. Read-only
#              roles, and NO `container.clusters.connect`, so it cannot reach
#              the API server at all (the cluster has only the DNS endpoint,
#              and that endpoint is gated by this permission).
#   apply SA : only runs on refs/heads/main may impersonate it. Can change
#              the infrastructure.
#
# Applied once by a human (project owner), after bootstrap/state.
#
# Naming, AWS -> GCP:
#   IAM OIDC provider            -> workload identity pool + provider
#   role trust policy conditions -> attribute condition + principalSet member
#   sts:AssumeRoleWithWebIdentity-> STS token exchange, then impersonate the SA
###
provider "google" {
  project = var.project_id
}

resource "google_project_service" "this" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

###
# Pool + provider. token.actions.githubusercontent.com is ONE issuer for every
# GitHub repository, so without the attribute condition any workflow in the
# world could present a valid token here. The condition pins the pool to our
# owner, by numeric ID: a name can be given up and taken by someone else.
###
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-com"
  display_name                       = "github.com"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    # allowed_audiences left unset: the default audience is this provider's
    # own resource URL, which is what google-github-actions/auth requests.
  }

  attribute_condition = "assertion.repository_owner_id == '${var.github_owner_id}'"

  # Only mapped attributes can be used in IAM bindings. A principalSet matches
  # ONE attribute, so "this repository AND main" is built here as a single
  # value, e.g. "12345:refs/heads/main".
  #
  # GitHub has no counterpart of GitLab's `ref_protected` claim, and on a
  # private repository without a paid plan neither environment branch rules nor
  # required reviewers exist. So the gate is the ref itself, checked by Google:
  # only code that is on main can get a token for main.
  attribute_mapping = {
    "google.subject"           = "assertion.sub"
    "attribute.repository_id"  = "assertion.repository_id"
    "attribute.repository_ref" = "assertion.repository_id + ':' + assertion.ref"
  }
}

locals {
  pool = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"

  # "Any ref" means any run of a workflow IN this repository. A pull request
  # from a fork does not get an OIDC token by default (no `id-token: write`),
  # so it gets nothing here. Review workflow changes before turning on "send
  # write tokens to workflows from fork pull requests".
  any_ref  = "${local.pool}/attribute.repository_id/${var.github_repository_id}"
  main_ref = "${local.pool}/attribute.repository_ref/${var.github_repository_id}:refs/heads/main"

  # Read-only, per service. Deliberately not the basic `roles/viewer`, and no
  # GKE role that carries `container.clusters.connect`.
  plan_roles = [
    "roles/compute.viewer",
    "roles/container.clusterViewer",
    "roles/iam.securityReviewer",
    "roles/iam.roleViewer",
    "roles/iam.serviceAccountViewer",
    "roles/serviceusage.serviceUsageViewer",
  ]

  # What the layers create. `projectIamAdmin` can grant any role, so this
  # account is owner-equivalent in practice; the protection is WHO may
  # impersonate it (main only), not the role list.
  apply_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.roleAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ]
}

###
# Plan — any ref of this project, read-only.
###
resource "google_service_account" "plan" {
  account_id   = "github-plan"
  display_name = "GitHub Actions: terraform plan (read-only)"

  # On a fresh project the IAM API is still off. Everything below hangs off
  # this account, so waiting here orders the whole chain.
  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "plan" {
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.any_ref
}

resource "google_project_iam_member" "plan" {
  for_each = toset(local.plan_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.plan.email}"
}

###
# Apply — main only.
###
resource "google_service_account" "apply" {
  account_id   = "github-apply"
  display_name = "GitHub Actions: terraform apply (main only)"

  # On a fresh project the IAM API is still off. Everything below hangs off
  # this account, so waiting here orders the whole chain.
  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "apply" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.main_ref
}

resource "google_project_iam_member" "apply" {
  for_each = toset(local.apply_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.apply.email}"
}

###
# State bucket (from bootstrap/state). plan runs with -lock=false, so reading
# objects is enough; apply writes state and the lock object.
###
resource "google_storage_bucket_iam_member" "plan_state" {
  bucket = var.tfstate_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.plan.email}"
}

resource "google_storage_bucket_iam_member" "apply_state" {
  bucket = var.tfstate_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.apply.email}"
}
