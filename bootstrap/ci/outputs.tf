output "workload_identity_provider" {
  description = "Goes into .gitlab-ci.yml as WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.gitlab.name
}

output "plan_service_account" {
  value = google_service_account.plan.email
}

output "apply_service_account" {
  value = google_service_account.apply.email
}
