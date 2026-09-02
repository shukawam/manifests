# ---------------------------------------
# Private Service Connect のサービス接続ポリシー
#
#   Valkey は PSC の自動接続でしか到達できず、これが無いと下の
#   google_memorystore_instance の作成自体が失敗する
# ---------------------------------------
resource "google_network_connectivity_service_connection_policy" "memorystore" {
  count = var.create_memorystore_valkey ? 1 : 0

  project       = var.project_id
  name          = format("%s-memorystore", var.resource_prefix)
  location      = var.region
  service_class = "gcp-memorystore"
  network       = google_compute_network.gke.id
  description   = "Memorystore for Valkey を GKE の VPC から PSC 経由で利用するためのサービス接続ポリシー"

  psc_config {
    subnetworks = [google_compute_subnetwork.psc[0].id]
  }

  depends_on = [google_project_service.this]
}

# ---------------------------------------
# Memorystore for Valkey
#   Kong のセマンティック系プラグイン (ai-semantic-cache 等) が使うベクター DB
# ---------------------------------------
resource "google_memorystore_instance" "valkey" {
  count = var.create_memorystore_valkey ? 1 : 0

  project     = var.project_id
  instance_id = format("%s-valkey", var.resource_prefix)
  location    = var.region

  # CLUSTER モードにすると Kong 側の redis 設定に cluster_nodes の列挙が要る
  mode          = "CLUSTER_DISABLED"
  shard_count   = var.valkey_shard_count
  replica_count = var.valkey_replica_count
  node_type     = var.valkey_node_type

  # ベクトル検索を含む Valkey 8 系の機能を前提にするため既定任せにしない
  engine_version = "VALKEY_8_0"

  # VPC 内からしか到達できない検証用なので掛けない。どちらも immutable で、
  # 後から有効化するとインスタンスの再作成になる。
  authorization_mode      = "AUTH_DISABLED"
  transit_encryption_mode = "TRANSIT_ENCRYPTION_DISABLED"

  deletion_protection_enabled = false

  desired_auto_created_endpoints {
    network    = google_compute_network.gke.id
    project_id = var.project_id
  }

  depends_on = [
    google_project_service.this,
    google_network_connectivity_service_connection_policy.memorystore,
  ]
}
