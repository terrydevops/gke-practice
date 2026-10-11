resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.name
  location = var.location

  # Start at the floor; the autoscaler owns the count from then on.
  initial_node_count = var.min_nodes

  # Cluster autoscaler, per pool. GKE Standard has no Karpenter-style "pick any
  # instance type" by default; that is node auto-provisioning or Autopilot.
  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Add one node before draining an old one during upgrades.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-balanced"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"] # IAM decides, not scopes

    # Pods see the GKE metadata server, not the node's. A pod without a
    # Workload Identity binding cannot borrow the node service account. Same
    # goal as IMDSv2 hop-limit 1 on EKS.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # GCP labels on the VMs (billing, ownership). `labels` here would set
    # Kubernetes node labels instead.
    resource_labels = var.labels

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
