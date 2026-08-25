# ---------------------------------------
# GKE Standard クラスタ
#
#   Autopilot ではなく Standard モードを使う理由:
#     Autopilot はノードの管理を GKE 側に委ねるため、hostPath / hostNetwork /
#     特権コンテナを伴う DaemonSet に強い制約がかかる。
#     OpenTelemetry Collector をノードごとの DaemonSet として配置し、
#     kubelet / ノードのファイルシステムからテレメトリを収集するには
#     ノードを自前で管理できる Standard モードが必要。
# ---------------------------------------
resource "google_container_cluster" "gke" {
  project = var.project_id
  name    = format("%s-gke", var.resource_prefix)

  # location にリージョンを指定してリージョナルクラスタにする
  # (コントロールプレーンが冗長化され、ノードは node_locations のゾーンに配置される)
  location       = var.region
  node_locations = var.zones

  # Standard モード
  #   enable_autopilot は明示しない。Google プロバイダでは enable_autopilot と
  #   remove_default_node_pool が排他扱いになるため、false を書くとエラーになる。
  #   属性を省略した場合の既定が Standard モード。

  # 既定ノードプールは作成直後に削除し、下の google_container_node_pool で管理する
  # (Terraform 上でノードプールをライフサイクル管理するための定石)
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.gke.id
  subnetwork = google_compute_subnetwork.gke.id

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = format("%s-gke-pods", var.resource_prefix)
    services_secondary_range_name = format("%s-gke-services", var.resource_prefix)
  }

  release_channel {
    channel = var.release_channel
  }

  # Workload Identity
  #   OpenTelemetry Collector が鍵ファイルなしで Google Cloud の
  #   Trace / Monitoring / Logging にエクスポートするために必須
  workload_identity_config {
    workload_pool = format("%s.svc.id.goog", var.project_id)
  }

  logging_config {
    enable_components = var.logging_components
  }

  monitoring_config {
    enable_components = var.monitoring_components

    managed_prometheus {
      enabled = var.enable_managed_prometheus
    }
  }

  # master_authorized_networks が空の場合はブロックごと出力せず、制限なしにする
  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []

    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks

        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # private_cluster_config は指定しない
  #   → コントロールプレーン・ノードともパブリック。手元から kubectl が直接通り、
  #     イメージ pull や外部への OTLP エクスポートもインターネットに直接出るため Cloud NAT 不要
  deletion_protection = var.deletion_protection

  depends_on = [google_project_service.this]
}

# ---------------------------------------
# ノードプール
#   OpenTelemetry Collector の DaemonSet はここに載るノード全台に 1 Pod ずつ配置される
# ---------------------------------------
resource "google_container_node_pool" "primary" {
  project  = var.project_id
  name     = format("%s-gke-node-pool", var.resource_prefix)
  location = google_container_cluster.gke.location
  cluster  = google_container_cluster.gke.name

  # ゾーンあたりのノード数
  initial_node_count = var.node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = var.disk_type
    image_type   = "COS_CONTAINERD"
    spot         = var.spot

    service_account = google_service_account.gke_node.email

    # 個別スコープではなく cloud-platform を付与し、実際の権限は上の IAM ロールで絞る
    # (Google が推奨する構成)
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = var.node_labels

    # Pod が Workload Identity 経由でのみ認証情報を取得できるようにする
    # (ノードのメタデータサーバへの直接アクセスを遮断)
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    # オートスケーラがノード数を変えるため、initial_node_count の差分は無視する
    ignore_changes = [initial_node_count]
  }
}
