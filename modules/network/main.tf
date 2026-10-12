###
# Network module — GCP only. A dedicated custom-mode VPC for one environment:
#
#   main.tf      VPC and its two subnets (nodes, proxy-only)
#   nat.tf       Cloud NAT on reserved static IPs, for the node subnet only
#   firewall.tf  VPC-wide baseline: logged default-deny in BOTH directions
#
# Differences from the EKS network layer worth knowing:
#   - A GCP VPC is global and a subnet is regional (it spans every zone), so
#     there is no "one subnet per AZ" fan-out.
#   - There is no public / private subnet split and no per-subnet route table.
#     A node is private because it has no external IP.
#   - The internet gateway is implicit (a default route every VPC gets).
#   - Firewall rules hang off the VPC and select instances by service account
#     or tag. They do the job of security groups and NACLs together.
###
locals {
  pods_range_name     = "pods"
  services_range_name = "services"
}

resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false # custom mode: no default subnets in every region
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.name}-nodes"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.nodes_cidr

  # Nodes have no external IP; this lets them reach Google APIs (Artifact
  # Registry, GCS, logging) over Google's network without going through NAT.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = var.services_cidr
  }

  # VPC Flow Logs: who talked to whom. Needed after an incident; sampled to
  # keep the bill sane.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = var.flow_log_sampling
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# There is no subnet for the control plane. With only the DNS-based endpoint
# switched on, GKE puts the control plane's internal address in the node subnet
# (seen as 10.10.0.2 in nonprod) and ignores a subnet offered for it.

# Google-managed Envoy proxies (internal / regional Application Load Balancers,
# i.e. the internal and regional GKE Gateway classes) take their IPs from here.
# Backends see these addresses as the source, so the range is what firewall
# rules and NetworkPolicies allow. No VM can be placed in this subnet.
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.name}-proxy-only"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.proxy_only_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
