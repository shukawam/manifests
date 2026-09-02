# ---------------------------------------
# GKE 専用 VPC
# ---------------------------------------
resource "google_compute_network" "gke" {
  project                 = var.project_id
  name                    = format("%s-gke-vpc", var.resource_prefix)
  auto_create_subnetworks = false

  depends_on = [google_project_service.this]
}

resource "google_compute_subnetwork" "gke" {
  project       = var.project_id
  name          = format("%s-gke-subnet", var.resource_prefix)
  region        = var.region
  network       = google_compute_network.gke.id
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = format("%s-gke-pods", var.resource_prefix)
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = format("%s-gke-services", var.resource_prefix)
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# ---------------------------------------
# Private Service Connect 用サブネット
#   ノード用サブネットを共用するとオートスケールで増えるノード IP とレンジを
#   取り合うため、Valkey のエンドポイント用に切り分けている
# ---------------------------------------
resource "google_compute_subnetwork" "psc" {
  count = var.create_memorystore_valkey ? 1 : 0

  project       = var.project_id
  name          = format("%s-psc-subnet", var.resource_prefix)
  region        = var.region
  network       = google_compute_network.gke.id
  ip_cidr_range = var.psc_subnet_cidr
}
