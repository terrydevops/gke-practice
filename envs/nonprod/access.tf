###
# Who may connect to the cluster now lives in bootstrap/ci/access.tf, so it
# survives a teardown of this environment. These blocks hand the objects over
# without deleting them; they can go once this root has been applied.
###
removed {
  from = google_project_iam_custom_role.cluster_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.cluster_connect

  lifecycle {
    destroy = false
  }
}
