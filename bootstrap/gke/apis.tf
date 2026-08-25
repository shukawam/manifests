# ---------------------------------------
# GKE 構築に必要な API
#   disable_on_destroy = false: terraform destroy でクラスタを消しても、
#   同一プロジェクト上の他リソースを巻き込まないよう API 自体は無効化しない
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
    # secretmanager: External Secrets Operator が Secret Manager からシークレットを取得するために必要
    # dns: cert-manager の DNS-01 チャレンジおよび gke.shukawam.me ゾーンの管理に必要
    # (このプロジェクトでは既に有効化済みのため apply 時は no-op になるが、
    #  設定の自己完結性のためここにも列挙する)
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
