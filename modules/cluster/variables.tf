variable "project_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "location" {
  description = "A zone (zonal cluster, one control plane) or a region (regional cluster, HA control plane)."
  type        = string
}

variable "network_id" {
  type = string
}

variable "subnetwork_id" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "proxy_only_cidr" {
  description = "Range of the proxy-only subnet; source of traffic from internal / regional load balancers."
  type        = string
}

variable "release_channel" {
  description = "RAPID, REGULAR or STABLE. Non-prod one step ahead of prod, so an upgrade is seen there first."
  type        = string
  default     = "REGULAR"
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "labels" {
  description = "Labels on the cluster and its nodes (cost allocation, ownership)."
  type        = map(string)
  default     = {}
}

variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}

variable "spot" {
  description = "Run the node pool on Spot VMs: much cheaper, but Google can reclaim a node with 30 s notice and PDBs are not honoured. Keep false for prod."
  type        = bool
  default     = false
}

variable "backend_ports" {
  description = "Container ports that internal / regional load balancers may reach."
  type        = list(string)
  default     = ["8080"]
}
