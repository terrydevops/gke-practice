###
# Firewall baseline for the whole VPC. No target is set, so these rules apply to
# every instance in the network.
#
# GCP already has an implied deny-ingress and an implied allow-egress, both
# invisible and unlogged. The baseline replaces them with explicit rules:
#   - ingress: an explicit deny, only to get the denied connections LOGGED.
#   - egress:  deny by default, then allow what a GKE node needs.
#
# Allow rules for traffic INTO the nodes are not here. GKE creates its own
# (node <-> node, pod <-> node), and the rest are
# cluster-specific and live in the cluster module, targeted by the node
# service account.
###
resource "google_compute_firewall" "deny_ingress" {
  name      = "${var.name}-deny-ingress"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 65534 # last word; every allow rule sits above it

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Inside the environment: node <-> node, node <-> pod, and nodes to the control
# plane, whose internal address sits in the node subnet (TCP 443, plus 8132 for
# the Konnectivity proxy).
resource "google_compute_firewall" "allow_egress_internal" {
  name      = "${var.name}-allow-egress-internal"
  network   = google_compute_network.this.id
  direction = "EGRESS"
  priority  = 1000

  destination_ranges = [
    var.nodes_cidr,
    var.pods_cidr,
  ]

  allow {
    protocol = "all"
  }
}

# Outside the VPC: HTTPS only. Google APIs reached through Private Google
# Access still have public destination addresses, so they need this rule too.
# DNS and NTP go to the metadata server (169.254.169.254), which the firewall
# never blocks.
resource "google_compute_firewall" "allow_egress_external" {
  name      = "${var.name}-allow-egress-external"
  network   = google_compute_network.this.id
  direction = "EGRESS"
  priority  = 1000

  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = var.egress_tcp_ports
  }
}

resource "google_compute_firewall" "deny_egress" {
  name      = "${var.name}-deny-egress"
  network   = google_compute_network.this.id
  direction = "EGRESS"
  priority  = 65534

  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  # A denied egress line here is either a missing allow rule or a workload
  # doing something it should not. Both are worth seeing.
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
