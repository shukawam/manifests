# ---------------------------------------
# ノード用サービスアカウント
#   Compute Engine の既定 SA (Editor 相当) を使わず、最小権限の専用 SA を割り当てる
# ---------------------------------------
resource "google_service_account" "gke_node" {
  project      = var.project_id
  account_id   = format("%s-gke-node", var.resource_prefix)
  display_name = format("%s-gke-node", var.resource_prefix)
  description  = "GKE Standard クラスタのノードが使用するサービスアカウント"

  depends_on = [google_project_service.this]
}

locals {
  # ノードが最低限必要とするロール
  #   - logging.logWriter / monitoring.metricWriter: kubelet・システムコンポーネントのテレメトリ送信
  #   - monitoring.viewer / stackdriver.resourceMetadata.writer: GKE メタデータエージェント
  #   - artifactregistry.reader: Artifact Registry からのイメージ pull
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]
}

resource "google_project_iam_member" "gke_node" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = format("serviceAccount:%s", google_service_account.gke_node.email)
}

# ---------------------------------------
# OpenTelemetry Collector 用サービスアカウント
#   DaemonSet として動く Collector が Cloud Trace / Monitoring / Logging に
#   エクスポートするための Workload Identity 連携
# ---------------------------------------
resource "google_service_account" "otel_collector" {
  count = var.create_otel_collector_service_account ? 1 : 0

  project      = var.project_id
  account_id   = format("%s-otel-collector", var.resource_prefix)
  display_name = format("%s-otel-collector", var.resource_prefix)
  description  = "OpenTelemetry Collector (DaemonSet) が Workload Identity 経由で借用するサービスアカウント"

  depends_on = [google_project_service.this]
}

locals {
  otel_collector_roles = [
    "roles/monitoring.metricWriter",
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
  ]
}

resource "google_project_iam_member" "otel_collector" {
  for_each = var.create_otel_collector_service_account ? toset(local.otel_collector_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = format("serviceAccount:%s", google_service_account.otel_collector[0].email)
}

# Kubernetes ServiceAccount → Google Service Account の借用を許可する
resource "google_service_account_iam_member" "otel_collector_workload_identity" {
  count = var.create_otel_collector_service_account ? 1 : 0

  service_account_id = google_service_account.otel_collector[0].name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "serviceAccount:%s.svc.id.goog[%s/%s]",
    var.project_id,
    var.otel_collector_namespace,
    var.otel_collector_ksa_name,
  )
}

# ---------------------------------------
# External Secrets Operator 用サービスアカウント
#   Secret Manager 上のシークレットを ExternalSecret 経由で取得するための
#   Workload Identity 連携
# ---------------------------------------
resource "google_service_account" "external_secrets" {
  project      = var.project_id
  account_id   = format("%s-external-secrets", var.resource_prefix)
  display_name = format("%s-external-secrets", var.resource_prefix)
  description  = "External Secrets Operator が Workload Identity 経由で借用するサービスアカウント"

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "external_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = format("serviceAccount:%s", google_service_account.external_secrets.email)
}

# Kubernetes ServiceAccount → Google Service Account の借用を許可する
#   バインド先の namespace / ServiceAccount 名 (external-secrets/external-secrets) は
#   マニフェスト側の Helm values で固定されるため、変数化せず定数で埋め込む
resource "google_service_account_iam_member" "external_secrets_workload_identity" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "serviceAccount:%s.svc.id.goog[external-secrets/external-secrets]",
    var.project_id,
  )
}

# ---------------------------------------
# cert-manager 用サービスアカウント
#   Cloud DNS の DNS-01 チャレンジで gke.shukawam.me 配下の証明書を発行するための
#   Workload Identity 連携
# ---------------------------------------
resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = format("%s-cert-manager", var.resource_prefix)
  display_name = format("%s-cert-manager", var.resource_prefix)
  description  = "cert-manager が Workload Identity 経由で借用するサービスアカウント (Cloud DNS DNS-01 チャレンジ用)"

  depends_on = [google_project_service.this]
}

# roles/dns.admin は使わない。cert-manager にはこの Terraform が管理するゾーンに対する
# レコード操作のみを許可すれば十分だが、dns.admin はプロジェクト内の全ゾーン
# (無関係な shukawam-zdf-gke クラスタが持つ private zone を含む) の作成・削除まで許してしまう。
# roles/dns.editor もゾーンの削除権限 (dns.managedZones.delete) を持つため不採用。
# 必要な操作だけに絞ったカスタムロールを定義する。
#
# dns.managedZones.list はプロジェクトスコープのまま残す必要がある。
# ClusterIssuer が hostedZoneName を指定していないため、cert-manager は DNS-01
# チャレンジのたびに対象ゾーンを list で自動発見する。ゾーンレベルの IAM 付与では
# list 操作 (プロジェクト全体を対象にするコレクション操作) を許可できない。
resource "google_project_iam_custom_role" "cert_manager_dns" {
  project     = var.project_id
  role_id     = "certManagerDns01"
  title       = "cert-manager DNS-01 solver"
  description = "cert-manager が DNS-01 チャレンジで Cloud DNS のレコードを操作するために必要な最小権限"

  permissions = [
    "dns.managedZones.list",
    "dns.managedZones.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.update",
    "dns.resourceRecordSets.delete",
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
  ]
}

resource "google_project_iam_member" "cert_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.cert_manager_dns.id
  member  = format("serviceAccount:%s", google_service_account.cert_manager.email)
}

# バインド先の namespace / ServiceAccount 名 (cert-manager/cert-manager) は
# マニフェスト側の Helm values で固定されるため、変数化せず定数で埋め込む
resource "google_service_account_iam_member" "cert_manager_workload_identity" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "serviceAccount:%s.svc.id.goog[cert-manager/cert-manager]",
    var.project_id,
  )
}
