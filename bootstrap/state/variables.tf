variable "project_id" {
  description = "GCP project that holds the state bucket."
  type        = string
}

variable "location" {
  description = "Bucket location, e.g. a region."
  type        = string
}
