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
#
# Kept here, not in envs/nonprod, because the environment is torn down and
# rebuilt: destroy only soft-deletes a custom role, and after 7 days its ID is
# blocked for weeks, so a later rebuild could not create it again.
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

  depends_on = [google_project_service.this] # needs the IAM API
}

resource "google_project_iam_member" "cluster_connect" {
  for_each = toset(var.cluster_users)

  project = var.project_id
  role    = google_project_iam_custom_role.cluster_connect.id
  member  = each.value
}

# Taken over from envs/nonprod's state (see the removed blocks there). Both
# can go once this root has been applied.
import {
  to = google_project_iam_custom_role.cluster_connect
  id = "projects/${var.project_id}/roles/gkeClusterConnect"
}

import {
  for_each = toset(var.cluster_users)
  to       = google_project_iam_member.cluster_connect[each.value]
  id       = "${var.project_id} projects/${var.project_id}/roles/gkeClusterConnect ${each.value}"
}
