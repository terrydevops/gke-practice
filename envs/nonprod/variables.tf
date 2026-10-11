variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "cluster_users" {
  description = "IAM members allowed to connect to the cluster, e.g. [\"user:alice@example.com\"]. Their rights inside come from RBAC."
  type        = list(string)
  default     = []
}
