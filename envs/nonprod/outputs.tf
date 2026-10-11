output "cluster_name" {
  value = module.cluster.cluster_name
}

output "get_credentials" {
  description = "Command that writes the kubeconfig entry."
  value       = "gcloud container clusters get-credentials ${module.cluster.cluster_name} --location ${module.cluster.location} --project ${var.project_id} --dns-endpoint"
}

output "workload_pool" {
  value = module.cluster.workload_pool
}

output "nat_ips" {
  value = module.network.nat_ips
}
