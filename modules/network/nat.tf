###
# Outbound: Cloud NAT on reserved IPs.
###
resource "google_compute_router" "this" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

# Reserved, so the egress addresses survive a NAT rebuild and can be given to
# a third party for allow-listing.
resource "google_compute_address" "nat" {
  count  = var.nat_ip_count
  name   = "${var.name}-nat-${count.index}"
  region = var.region
}

resource "google_compute_router_nat" "this" {
  name   = "${var.name}-nat"
  region = var.region
  router = google_compute_router.this.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

  # Only the node subnet (node IPs + pod IPs) may use NAT. A subnet added to
  # this VPC later gets no internet egress until it is listed here.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.nodes.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # A GKE node NATs for every pod on it, so a fixed per-VM port quota runs out
  # under load (dropped connections, OUT_OF_RESOURCES in the NAT logs). Dynamic
  # allocation grows a busy node's share on demand; 64 / 2048 are the values in
  # Google's GKE networking guide. It requires endpoint-independent mapping off.
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 64
  max_ports_per_vm                    = 2048

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
