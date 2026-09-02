# ---------------------------------------
# Cloud DNS: gke.shukawam.me サブドメイン用パブリックゾーン
#
#   shukawam.me 本体の権威 DNS は dnsv.jp 側にあり、gke サブドメインだけを
#   Cloud DNS へ NS 委任している。委任は Terraform の範囲外の手動作業なので、
#   apply 後に dns_zone_name_servers の出力値を dnsv.jp 側へ設定すること。
# ---------------------------------------
resource "google_dns_managed_zone" "gke" {
  project     = var.project_id
  name        = format("%s-gke-zone", var.resource_prefix)
  dns_name    = "gke.shukawam.me."
  description = "gke.shukawam.me サブドメイン用パブリックゾーン"
  visibility  = "public"

  # cert-manager が DNS-01 で書く _acme-challenge の TXT が消し残るとゾーンが
  # 空にならず destroy が失敗する。管理外で存在し得るのはこの一時レコードだけ。
  force_destroy = true

  depends_on = [google_project_service.this]
}

# 個別レコードを持たないホスト名はすべて Kong Gateway 用の IP に解決する
resource "google_dns_record_set" "wildcard" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gke.name
  name         = "*.gke.shukawam.me."
  type         = "A"
  # 手動で IP を張り替えて反復する可能性があるため既定 (300 秒) より短くする
  ttl     = 60
  rrdatas = [google_compute_address.gateway.address]
}
