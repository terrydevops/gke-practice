###
# Secrets that outlive the cluster. Terraform creates the secret and who may
# read it, never a version: the value is added by hand (gitops/README.md,
# "Monitoring" and "Commit status"), so it is in neither git nor state.
#
# Read through Workload Identity Federation by one Kubernetes service account,
# named here: no Google service account in between. The binding does not need
# the cluster to exist, so it survives a teardown.
###
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # A Kubernetes service account as an IAM principal: <pool>/subject/ns/<ns>/sa/<sa>
  ksa_principal = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject"
}

resource "google_secret_manager_secret" "grafana_admin" {
  secret_id = "grafana-admin-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_iam_member" "grafana_admin" {
  secret_id = google_secret_manager_secret.grafana_admin.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.ksa_principal}/ns/monitoring/sa/grafana-secrets"
}

# GitHub App credentials for Flux's commit status (gitops/README.md, "Commit
# status"): one JSON object with githubAppID, githubAppInstallationID and
# githubAppPrivateKey.
resource "google_secret_manager_secret" "flux_github" {
  secret_id = "flux-github-commit-status"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_iam_member" "flux_github" {
  secret_id = google_secret_manager_secret.flux_github.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.ksa_principal}/ns/flux-system/sa/flux-github-secrets"
}

# Token of the named Cloudflare Tunnel behind the public explorer
# (docs/esplora-explorer.md). The tunnel itself is created in the Cloudflare
# dashboard; only its token is kept here.
resource "google_secret_manager_secret" "cloudflared_token" {
  secret_id = "cloudflared-tunnel-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_iam_member" "cloudflared_token" {
  secret_id = google_secret_manager_secret.cloudflared_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "${local.ksa_principal}/ns/cloudflared/sa/cloudflared-secrets"
}
