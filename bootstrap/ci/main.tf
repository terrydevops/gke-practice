###
# Bootstrap, step 2: CI/CD identity (GCP only) — Workload Identity Federation for GitLab plus
# the two service accounts the pipeline impersonates. No service-account keys:
# the pipeline proves who it is with a short-lived GitLab ID token.
# Counterpart of eks-practice/v2/ci.
#
#   plan SA  : any branch of this GitLab project may impersonate it. Read-only
#              roles, and NO `container.clusters.connect`, so it cannot reach
#              the API server at all (the cluster has only the DNS endpoint,
#              and that endpoint is gated by this permission).
#   apply SA : only pipelines on a PROTECTED ref may impersonate it. Can change
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
# Pool + provider. gitlab.com is ONE issuer for every GitLab customer, so
# without the attribute condition any GitLab.com pipeline in the world could
# present a valid token here. The condition pins the pool to our namespace.
###
resource "google_iam_workload_identity_pool" "gitlab" {
  workload_identity_pool_id = "gitlab"
  display_name              = "GitLab CI"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "gitlab" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab.workload_identity_pool_id
  workload_identity_pool_provider_id = "gitlab-com"
  display_name                       = "gitlab.com"

  oidc {
    issuer_uri = "https://gitlab.com"
    # allowed_audiences left unset: the default audience is this provider's
    # own resource URL, which is what the job requests in `id_tokens.aud`.
  }

  attribute_condition = "assertion.namespace_id == '${var.gitlab_namespace_id}'"

  # Only mapped attributes can be used in IAM bindings. A principalSet matches
  # ONE attribute, so "this project AND a protected ref" is built here as a
  # single value, e.g. "12345:true".
  attribute_mapping = {
    "google.subject"              = "assertion.sub"
    "attribute.project_id"        = "assertion.project_id"
    "attribute.project_protected" = "assertion.project_id + ':' + assertion.ref_protected"
  }
}

locals {
  pool = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab.name}"

  # "Any ref" means any pipeline that runs IN this GitLab project. If the
  # repository ever becomes public: a merge request from a fork runs in the
  # fork, with the fork's project ID, and gets nothing -- unless a member chooses
  # to run that pipeline in this project. Then the fork's code plans as the plan
  # account. Review the diff of .gitlab-ci.yml before doing that.
  any_ref       = "${local.pool}/attribute.project_id/${var.gitlab_project_id}"
  protected_ref = "${local.pool}/attribute.project_protected/${var.gitlab_project_id}:true"

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
  # impersonate it (protected refs only), not the role list.
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
  account_id   = "gitlab-plan"
  display_name = "GitLab CI: terraform plan (read-only)"

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
# Apply — protected refs only.
###
resource "google_service_account" "apply" {
  account_id   = "gitlab-apply"
  display_name = "GitLab CI: terraform apply (protected refs only)"

  # On a fresh project the IAM API is still off. Everything below hangs off
  # this account, so waiting here orders the whole chain.
  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "apply" {
  service_account_id = google_service_account.apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.protected_ref
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
