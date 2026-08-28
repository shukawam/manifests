# ---------------------------------------
# L4 RBS (リージョナルパススルー Network Load Balancer) 用の静的外部 IP
#
#   GKE の Service (type: LoadBalancer) が作るのはリージョナルなパススルー
#   Network Load Balancer であり、グローバル静的 IP は紐付けられない。
#   そのため google_compute_global_address ではなく、リージョナルな
#   google_compute_address を使う。
#
#   address_type / network_tier はプロバイダの既定値と一致するが、
#   担当者に推測させないよう明示的に指定する。
# ---------------------------------------
resource "google_compute_address" "gateway" {
  project = var.project_id
  name    = format("%s-gke-gateway", var.resource_prefix)
  region  = var.region

  address_type = "EXTERNAL"
  network_tier = "PREMIUM"

  depends_on = [google_project_service.this]
}
