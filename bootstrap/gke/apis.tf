# ---------------------------------------
# GKE 構築に必要な API
#   destroy 時も API 自体は無効化しない (同一プロジェクトの他リソースを巻き込むため)
# ---------------------------------------
locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "memorystore.googleapis.com",
    # Valkey へ到達するための Private Service Connect のサービス接続ポリシーに必要
    "networkconnectivity.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
