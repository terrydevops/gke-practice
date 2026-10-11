###
# Remote state. Commented out while the repo is plan-only: with this block
# active, `terraform init` needs the bucket from bootstrap/state to exist.
# Before the first real apply (and before CI may apply): apply bootstrap/state,
# uncomment, then
#   terraform init -migrate-state -backend-config="bucket=<state bucket>"
# The bucket name is passed at init time so it never has to be committed.
###
# terraform {
#   backend "gcs" {
#     prefix = "envs/nonprod"
#   }
# }
