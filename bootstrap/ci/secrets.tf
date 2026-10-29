###
# Secrets that outlive the cluster. Terraform creates the secret and who may
# read it, never a version: the value is added by hand (gitops/README.md,
# "Monitoring"), so it is in neither git nor state.
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
