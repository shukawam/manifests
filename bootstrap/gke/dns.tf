# ---------------------------------------
# Cloud DNS: gke.shukawam.me サブドメイン用パブリックゾーン
#
#   shukawam.me 本体の権威 DNS は 01.dnsv.jp / 02.dnsv.jp にあり Cloud DNS の
#   管理下にない。gke サブドメインだけを Cloud DNS へ NS 委任する構成のため、
#   shukawam.me 本体の設定には一切触れない。
#   NS 委任自体 (dnsv.jp 側の作業) はこの Terraform の範囲外の手動作業。
#   apply 後は dns_zone_name_servers の出力値を dnsv.jp 側に設定すること。
# ---------------------------------------
resource "google_dns_managed_zone" "gke" {
  project     = var.project_id
  name        = format("%s-gke-zone", var.resource_prefix)
  dns_name    = "gke.shukawam.me."
  description = "gke.shukawam.me サブドメイン用パブリックゾーン"
  visibility  = "public"

  # cert-manager が DNS-01 チャレンジ時に _acme-challenge の TXT レコードを書き込む。
  # チャレンジが失敗して消し忘れたレコードが残っていると、ゾーンが空でないため
  # terraform destroy が失敗する。このゾーンに Terraform 管理外で存在し得るのは
  # ACME の一時レコードだけなので、force_destroy で destroy を通す。
  force_destroy = true

  depends_on = [google_project_service.this]
}

# ワイルドカード: argocd.gke.shukawam.me など個別レコードがないホスト名は
# すべて Kong Gateway (Gateway API DataPlane) 用 IP に解決する
resource "google_dns_record_set" "wildcard" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gke.name
  name         = "*.gke.shukawam.me."
  type         = "A"
  # 静的 IP の annotation が実機で効かない場合、手動で IP を張り替えて反復する
  # 可能性があるため、既定 (300 秒) より短い 60 秒にして反映待ちを短縮する。
  ttl     = 60
  rrdatas = [google_compute_address.gateway.address]
}

# aigw.gke.shukawam.me はワイルドカードより優先される個別レコードとして
# Kong AI Gateway 用 IP に解決する
resource "google_dns_record_set" "aigw" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.gke.name
  name         = "aigw.gke.shukawam.me."
  type         = "A"
  # wildcard レコードと同じ理由 (手動での IP 張り替えを想定した反映待ち短縮)
  ttl     = 60
  rrdatas = [google_compute_address.aigw.address]
}
