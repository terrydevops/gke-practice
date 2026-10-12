variable "name" {
  description = "Prefix for the VPC, subnets, router, NAT and firewall rules."
  type        = string
}

variable "region" {
  type = string
}

###
# IP plan. Every range of the environment is decided here, in one place, so
# overlaps are caught in review and the firewall rules can refer to them.
###
variable "nodes_cidr" {
  description = "Primary subnet range: node IPs."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range: pod IPs (alias IPs, VPC-native). Each node takes a /24 at the default 110 pods per node, so a /16 holds about 256 nodes."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range: ClusterIP services. Virtual; never seen by the VPC firewall."
  type        = string
}

variable "proxy_only_cidr" {
  description = "Proxy-only subnet for Google-managed Envoy load balancers (internal / regional Gateways). Google recommends a /23."
  type        = string
}

variable "nat_ip_count" {
  description = "Reserved static egress IPs. Static so partners can allow-list them; two so one can be drained."
  type        = number
  default     = 2
}

variable "egress_tcp_ports" {
  description = "TCP ports nodes and pods may reach outside the VPC. 443 covers Google APIs, image registries and Git over HTTPS."
  type        = list(string)
  default     = ["443"]
}

variable "flow_log_sampling" {
  description = "Share of flows written to VPC Flow Logs (0.0 - 1.0). Higher is better for forensics and costs more."
  type        = number
  default     = 0.1
}
