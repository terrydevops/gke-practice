variable "project_id" {
  description = "GCP project the pipeline deploys into."
  type        = string
}

variable "tfstate_bucket" {
  description = "Output of bootstrap/state."
  type        = string
}

# Numeric IDs, not names: a name can be renamed or re-registered by someone
# else, an ID cannot. `gh api repos/<owner>/<repo> --jq '.owner.id, .id'`
# prints both.
variable "github_owner_id" {
  description = "Numeric ID of the GitHub user or organization that owns the repository."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository."
  type        = string
}

variable "cluster_users" {
  description = "IAM members allowed to connect to the cluster, e.g. [\"user:alice@example.com\"]. Their rights inside come from RBAC."
  type        = list(string)
  default     = []
}
