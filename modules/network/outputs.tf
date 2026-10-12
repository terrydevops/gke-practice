output "network_id" {
  value = google_compute_network.this.id
}

output "subnetwork_id" {
  value = google_compute_subnetwork.nodes.id
}

output "pods_range_name" {
  value = local.pods_range_name
}

output "services_range_name" {
  value = local.services_range_name
}

output "proxy_only_cidr" {
  value = google_compute_subnetwork.proxy_only.ip_cidr_range
}

output "nat_ips" {
  description = "Static egress addresses, for partner allow-lists."
  value       = google_compute_address.nat[*].address
}
