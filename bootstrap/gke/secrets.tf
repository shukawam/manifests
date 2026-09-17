# ---------------------------------------
# Secret Manager の箱
#   値 (バージョン) は Terraform で作らない。state に平文で残るため、作成後に
#   gcloud で投入する。ESO はバージョンが 1 つも無い箱を参照すると
#   SecretSyncedError のまま Secret を作らないので、値の投入までが 1 セット。
#   ESO 側の参照権限は service-accounts.tf の google_project_iam_member.external_secrets
#   (プロジェクト全体の secretAccessor) でまかなえるため、個別の IAM は付けない。
#
#   deletion_protection はいずれも true。値はリポジトリから再生成できず、箱ごと消えると
#   復旧手段が無いため、destroy したいときは明示的に false へ倒してから apply する
#   (この 1 往復がそのまま「本当に消してよいか」の確認になる)。
# ---------------------------------------
resource "google_secret_manager_secret" "new_relic_license_key" {
  project   = var.project_id
  secret_id = "new-relic-license-key"

  # OpenTelemetry Collector から New Relic へ OTLP を送るための Ingest License Key。
  # User Key ではないことに注意 (User Key を入れると New Relic が 401 を返す)
  deletion_protection = true

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}

# Argo CD の Web UI / CLI が使う Auth0 OIDC クライアントシークレット。
# 参照元は platform/argo-cd/values.yaml の ExternalSecret
resource "google_secret_manager_secret" "argocd_auth0_client_secret" {
  project   = var.project_id
  secret_id = "argocd-auth0-client-secret"

  deletion_protection = true

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}

# pii-sanitizer のイメージを引く Cloudsmith の dockerconfigjson。
# 参照元は platform/pii-sanitizer/externalsecret.yaml
resource "google_secret_manager_secret" "pii_sanitizer_cloudsmith_dockerconfigjson" {
  project   = var.project_id
  secret_id = "pii-sanitizer-cloudsmith-dockerconfigjson"

  deletion_protection = true

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}
