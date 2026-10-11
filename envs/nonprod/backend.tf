###
# Remote state for this root (switched on in the order given in docs/state.md).
# The bucket name is passed at init time and is never committed:
#   terraform init -backend-config="bucket=<state bucket>"
#
# State object: gs://<state bucket>/envs/nonprod/default.tfstate
# Lock object:  gs://<state bucket>/envs/nonprod/default.tflock (created and removed
#               by Terraform; GCS needs no separate lock table)
###
terraform {
  backend "gcs" {
    prefix = "envs/nonprod"
  }
}
