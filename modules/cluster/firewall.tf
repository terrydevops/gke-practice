###
# Ingress to the nodes. The VPC baseline (network module) denies and logs
# everything; GKE adds its own rules for node <-> node and pod <-> node.
# Anything else is opened here, one rule per reason.
#
# Nothing is opened for the control plane. It has no range of its own here (its
# internal address is in the node subnet) and GKE creates no control-plane
# rule; it reaches the nodes through the Konnectivity tunnel, which the nodes
# open outwards. Admission webhooks are expected to arrive the same way, from
# inside the cluster. Not yet proven here: no webhook has been installed.
#
# Rules select the nodes by SERVICE ACCOUNT, not by network tag: a tag can be
# put on any VM by whoever may edit instances, a service account cannot be
# borrowed that way. Same idea as referencing a security group instead of a
# CIDR.
###

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
