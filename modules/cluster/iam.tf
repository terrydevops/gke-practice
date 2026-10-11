# Node identity. Without this, nodes run as the Compute Engine default service
# account, which usually carries the broad Editor role. This is the GKE
# counterpart of keeping the EKS node role minimal.
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

# One predefined role with what a node needs: write logs and metrics, read
# images from Artifact Registry.
resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}
