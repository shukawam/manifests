# ---------------------------------------
# GKE Standard クラスタ
#
#   Autopilot は hostPath / hostNetwork / 特権コンテナを伴う DaemonSet に強い
#   制約をかけるため、ノードのファイルシステムからテレメトリを収集する
#   OpenTelemetry Collector を置けない。
# ---------------------------------------
resource "google_container_cluster" "gke" {
  project = var.project_id
  name    = format("%s-gke", var.resource_prefix)

  location       = var.region
  node_locations = var.zones

  # enable_autopilot は書かない。remove_default_node_pool と排他扱いのため
  # false を書くとエラーになり、省略時の既定が Standard モードになる。

  # 既定ノードプールは作成直後に捨て、下の google_container_node_pool で管理する
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

  # private_cluster_config は指定しない。手元から kubectl が直接通り、外向き通信も
  # インターネットへ直接出るため Cloud NAT が要らない。
  deletion_protection = var.deletion_protection

  depends_on = [google_project_service.this]
}

# ---------------------------------------
# ノードプール
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

    # 個別スコープではなく cloud-platform を付与し、実際の権限は SA の IAM ロールで
    # 絞る (Google が推奨する構成)
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = var.node_labels

    # ノードのメタデータサーバへの直接アクセスを遮断する
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
