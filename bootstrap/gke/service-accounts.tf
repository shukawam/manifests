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
  # monitoring.viewer / stackdriver.resourceMetadata.writer は GKE メタデータ
  # エージェントが使う
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

# バインド先の namespace / ServiceAccount 名はマニフェスト側の Helm values で
# 固定されるため、変数化せず定数で埋め込む
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
# ---------------------------------------
resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = format("%s-cert-manager", var.resource_prefix)
  display_name = format("%s-cert-manager", var.resource_prefix)
  description  = "cert-manager が Workload Identity 経由で借用するサービスアカウント (Cloud DNS DNS-01 チャレンジ用)"

  depends_on = [google_project_service.this]
}

# roles/dns.admin も dns.editor も、プロジェクト内の無関係なゾーン
# (shukawam-zdf-gke の private zone 等) の削除まで許してしまうため使わない。
#
# dns.managedZones.list だけはプロジェクトスコープで残す必要がある。ClusterIssuer が
# hostedZoneName を指定しておらず cert-manager が毎回ゾーンを list で自動発見するが、
# list はコレクション操作なのでゾーンレベルの IAM 付与では許可できない。
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

# バインド先はマニフェスト側の Helm values で固定されるため定数で埋め込む
resource "google_service_account_iam_member" "cert_manager_workload_identity" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "serviceAccount:%s.svc.id.goog[cert-manager/cert-manager]",
    var.project_id,
  )
}

# ---------------------------------------
# Kong AI Gateway 用サービスアカウント
#   Konnect 側 config の use_gcp_service_account: true が指す連携先
# ---------------------------------------
resource "google_service_account" "kong_ai_gateway" {
  project      = var.project_id
  account_id   = format("%s-kong-ai-gateway", var.resource_prefix)
  display_name = format("%s-kong-ai-gateway", var.resource_prefix)
  description  = "kong-ai-gateway が Workload Identity 経由で借用し、Vertex AI (Anthropic モデル) を呼び出すためのサービスアカウント"

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "kong_ai_gateway" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = format("serviceAccount:%s", google_service_account.kong_ai_gateway.email)
}

# バインド先の ServiceAccount 名は Helm chart のフルネーム規則で決まるため定数で埋め込む
resource "google_service_account_iam_member" "kong_ai_gateway_workload_identity" {
  service_account_id = google_service_account.kong_ai_gateway.name
  role               = "roles/iam.workloadIdentityUser"
  member = format(
    "serviceAccount:%s.svc.id.goog[kong/kong-ai-gateway-kong-ai-gateway]",
    var.project_id,
  )
}
