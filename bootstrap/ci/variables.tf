variable "project_id" {
  description = "GCP project the pipeline deploys into."
  type        = string
}

variable "tfstate_bucket" {
  description = "Output of bootstrap/state."
  type        = string
}

# Numeric IDs, not paths: a path can be renamed or re-registered by someone
# else, an ID cannot. Both are on the project's / group's GitLab overview page.
variable "gitlab_namespace_id" {
  description = "Numeric ID of the GitLab group or user namespace that owns the repository."
  type        = string
}

variable "gitlab_project_id" {
  description = "Numeric ID of the GitLab project."
  type        = string
}
