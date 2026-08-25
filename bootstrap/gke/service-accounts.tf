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
