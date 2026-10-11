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

output "proxy_only_cidr" {
  description = "Goes into the cluster-vars ConfigMap that Flux substitutes from."
  value       = module.network.proxy_only_cidr
}
