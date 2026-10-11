###
# Human access to the cluster. Two layers, kept apart on purpose:
#
#   IAM  (here)   : may this identity REACH the API server at all?
#   RBAC (GitOps) : what may it do once inside?
#
# The predefined roles that carry `container.clusters.connect`
# (container.viewer, container.developer, container.admin) also grant
# Kubernetes permissions straight from IAM, project-wide and outside git. This
# custom role grants the connection and nothing else, so every in-cluster right
# is an RBAC binding that lives in the GitOps repo. Counterpart of the
# `eks-admin` role in eks-practice v2 (no AWS power, cluster rights only).
###
resource "google_project_iam_custom_role" "cluster_connect" {
  role_id     = "gkeClusterConnect"
  title       = "GKE cluster connect"
  description = "Find a cluster and reach its DNS endpoint. No Kubernetes permissions."

  permissions = [
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.connect",
  ]
}

resource "google_project_iam_member" "cluster_connect" {
  for_each = toset(var.cluster_users)

  project = var.project_id
  role    = google_project_iam_custom_role.cluster_connect.id
  member  = each.value
}
