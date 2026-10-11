###
# Non-prod environment: one shared cluster (dev + staging as namespaces), the
# same shape as eks-practice v2.
#
# Network and cluster sit in ONE root while nothing here is applied: with
# separate states the cluster layer would read the network layer through remote
# state, and that cannot be planned before the network is applied. Split into
# network / cluster layers once the network exists (docs/state.md).
###
locals {
  name = "gke-practice-nonprod"

  labels = {
    env        = "nonprod"
    managed-by = "terraform"
    repo       = "gke-practice"
  }
}

# A new project has almost every API switched off. On AWS every service is
# callable from day one; on GCP enabling the API is step zero.
resource "google_project_service" "this" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com", # project IAM bindings
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com", # Cloud DNS for GKE
    "iam.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source = "../../modules/network"

  name   = local.name
  region = var.region

  # IP plan for this environment. prod gets different blocks, so the two can be
  # peered or share a VPN later without renumbering.
  nodes_cidr         = "10.10.0.0/22" # ~1000 node and internal-LB addresses
  pods_cidr          = "10.20.0.0/16" # a /24 per node -> ~256 nodes; the real ceiling
  services_cidr      = "10.30.0.0/20"
  proxy_only_cidr    = "10.40.0.0/23"
  control_plane_cidr = "10.50.0.0/28"

  depends_on = [google_project_service.this]
}

module "cluster" {
  source = "../../modules/cluster"

  project_id   = var.project_id
  cluster_name = local.name
  location     = var.zone # zonal: one control plane, enough for practice; prod passes the region

  network_id          = module.network.network_id
  subnetwork_id       = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  control_plane_subnetwork_id = module.network.control_plane_subnetwork_id
  control_plane_cidr          = module.network.control_plane_cidr
  proxy_only_cidr             = module.network.proxy_only_cidr

  release_channel     = "REGULAR"
  deletion_protection = false # practice cluster; prod leaves the default (true)
  labels              = local.labels

  # The node service account references nothing in the network module, so
  # without this it could be created before the IAM API is enabled.
  depends_on = [google_project_service.this]
}
