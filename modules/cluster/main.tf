###
# Cluster module — GCP only (NO kubernetes/helm providers), same rule as the EKS
# practice repo: Terraform owns the cloud side, GitOps owns everything in-cluster.
#
#   main.tf       the cluster: private, VPC-native, DNS-only control plane
#   node_pool.tf  one autoscaled node pool
#   iam.tf        the nodes' own least-privilege service account
#   firewall.tf   rules that let traffic INTO this cluster's nodes
#
# Settings follow Google's "Harden your cluster's security" and "Best practices
# for GKE networking" guides as read on 2026-10-11. Each block says which
# recommendation it implements.
###

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.location

  network    = var.network_id
  subnetwork = var.subnetwork_id

  # The API insists on a default pool at creation. Create the smallest one and
  # delete it at once, so every node pool is a separate resource that can be
  # changed or replaced without touching the cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Even that short-lived pool must not run as the Compute Engine default
  # service account. Only the identity is set here; the real node settings are
  # in node_pool.tf, hence ignore_changes below.
  node_config {
    service_account = google_service_account.nodes.email
  }

  # VPC-native: pods and services take their IPs from the subnet's secondary
  # ranges, so pod IPs are routable in the VPC without an overlay.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # "Isolate your nodes from the internet": no external IPs on nodes. The
  # control plane's internal endpoint takes an address from a subnet we own.
  private_cluster_config {
    enable_private_nodes        = true
    private_endpoint_subnetwork = var.control_plane_subnetwork_id
  }

  # "Use only the DNS-based endpoint to access your control plane". kubectl and
  # CI reach a Google-fronted DNS name and are authorised by IAM, then RBAC.
  # Both IP endpoints are off, so there is no API server address to scan, no
  # authorized-networks list to maintain and no bastion to run.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = false
    }
  }

  # "Restrict anonymous access to cluster endpoints": unauthenticated requests
  # are limited to the health endpoints.
  anonymous_authentication_config {
    mode = "LIMITED"
  }

  # "Use Workload Identity Federation for GKE": a Kubernetes ServiceAccount can
  # act as a Google identity with no key file. Counterpart of EKS Pod Identity.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Dataplane V2 (eBPF, Cilium-based): NetworkPolicy enforcement is built in, so
  # no separate policy addon is needed.
  datapath_provider = "ADVANCED_DATAPATH"

  # "Disable the insecure kubelet read-only port" (10255) for every node pool.
  node_pool_defaults {
    node_config_defaults {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  # "Use Cloud DNS for GKE" and "Enable NodeLocal DNSCache": cluster DNS is
  # served by Google's managed DNS instead of kube-dns pods, with a cache on
  # every node.
  dns_config {
    cluster_dns       = "CLOUD_DNS"
    cluster_dns_scope = "CLUSTER_SCOPE"
  }

  addons_config {
    dns_cache_config {
      enabled = true
    }
  }

  # Gateway API CRDs and controller, for the internal / regional gateways that
  # use the proxy-only subnet.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # "Upgrade your GKE infrastructure regularly": Google upgrades the control
  # plane and nodes on this channel's schedule...
  release_channel {
    channel = var.release_channel
  }

  # ...but only inside this window: 15:00-19:00 UTC, Monday to Wednesday. Pick
  # the hours for when the cluster's users are asleep and its operators are not
  # on a weekend; nothing should land with nobody watching.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-05T15:00:00Z" # a Monday, matching BYDAY
      end_time   = "2026-01-05T19:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=MO,TU,WE"
    }
  }

  # "Monitor your resources for security issues": misconfiguration findings in
  # the security posture dashboard.
  security_posture_config {
    mode = "BASIC"
  }

  # Per-namespace and per-label cost breakdown in billing export.
  cost_management_config {
    enabled = true
  }

  # "Use tags to group Google Cloud resources".
  resource_labels = var.labels

  # false only for a throwaway cluster; true blocks `terraform destroy`.
  deletion_protection = var.deletion_protection

  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [google_project_iam_member.nodes]
}
