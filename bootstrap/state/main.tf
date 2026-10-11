###
# Bootstrap, step 1 — the one thing that must exist before any other layer can keep
# remote state: a GCS bucket. Counterpart of eks-practice/bootstrap (S3 + DynamoDB).
#
# GCS needs no lock table: the gcs backend locks with an object in the bucket.
#
# Chicken and egg: this root creates the bucket, so its FIRST apply can only
# use local state. Right after that its own state is moved into the bucket
# (backend.tf.disabled -> backend.tf, `terraform init -migrate-state`), so no
# state is left on a laptop. docs/state.md has the exact steps.
###
provider "google" {
  project = var.project_id
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "tfstate" {
  name     = "${var.project_id}-tfstate"
  location = var.location

  # IAM only, no per-object ACLs; and never public, whatever anyone sets later.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # State holds resource attributes in clear text. Keep old versions so a bad
  # apply or a deleted state file can be rolled back.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 30
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.storage]
}
