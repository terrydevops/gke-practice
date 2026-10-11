###
# Ingress to the nodes. The VPC baseline (network module) denies and logs
# everything; GKE adds its own rules for node <-> node, pod <-> node and
# control plane -> kubelet (TCP 443, 10250). Anything else is opened here, one
# rule per reason.
#
# Rules select the nodes by SERVICE ACCOUNT, not by network tag: a tag can be
# put on any VM by whoever may edit instances, a service account cannot be
# borrowed that way. Same idea as referencing a security group instead of a
# CIDR.
###

# The API server calls admission webhooks on the pod's own port. Without this
# rule, creating a resource guarded by a webhook hangs and times out.
resource "google_compute_firewall" "control_plane_webhooks" {
  name      = "${var.cluster_name}-allow-control-plane-webhooks"
  network   = var.network_id
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = [var.control_plane_cidr]
  target_service_accounts = [google_service_account.nodes.email]

  allow {
    protocol = "tcp"
    ports    = var.webhook_ports
  }
}

# Internal / regional load balancers: the Envoy proxies connect from the
# proxy-only subnet straight to pod IPs (container-native load balancing).
resource "google_compute_firewall" "proxy_to_backends" {
  name      = "${var.cluster_name}-allow-proxy-to-backends"
  network   = var.network_id
  direction = "INGRESS"
  priority  = 1000

  source_ranges           = [var.proxy_only_cidr]
  target_service_accounts = [google_service_account.nodes.email]

  allow {
    protocol = "tcp"
    ports    = var.backend_ports
  }
}
