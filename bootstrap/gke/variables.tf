# ---------------------------------------
# Common
# ---------------------------------------
variable "resource_prefix" {
  type        = string
  description = "全リソース名の接頭辞。各リソース名は format(\"%s-xxx\", var.resource_prefix) で組み立てる"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,17})[a-z0-9]$", var.resource_prefix))
    error_message = "resource_prefix は小文字英数字とハイフンのみ、2〜19 文字。サービスアカウント ID (最大 30 文字) の制約に収めるため長さを制限している"
  }
}

# ---------------------------------------
# Google Cloud
# ---------------------------------------
variable "project_id" {
  type        = string
  description = "GKE クラスタを構築する Google Cloud プロジェクト ID"
}

variable "region" {
  type        = string
  description = "クラスタ / サブネットを配置するリージョン"
  default     = "asia-northeast1"
}

variable "zones" {
  type        = list(string)
  description = <<-EOT
    ノードを配置するゾーン。
    空リストの場合はリージョン内の全ゾーンにノードが分散される (= 完全なリージョナルクラスタ)。
    検証環境でノード数を抑えたい場合は ["asia-northeast1-a"] のように単一ゾーンを指定する。
  EOT
  default     = ["asia-northeast1-a"]
}

variable "enable_apis" {
  type        = bool
  description = "GKE に必要な Google Cloud API をこの Terraform で有効化するか。既に有効化済みの組織/プロジェクトでは false にする"
  default     = true
}

# ---------------------------------------
# Network
# ---------------------------------------
variable "subnet_cidr" {
  type        = string
  description = "ノード用サブネットのプライマリ CIDR"
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  type        = string
  description = "Pod 用セカンダリレンジの CIDR (VPC-native)"
  default     = "10.21.0.0/16"
}

variable "services_cidr" {
  type        = string
  description = "Service 用セカンダリレンジの CIDR (VPC-native)"
  default     = "10.22.0.0/20"
}

variable "psc_subnet_cidr" {
  type        = string
  description = <<-EOT
    Private Service Connect のエンドポイント用サブネットの CIDR。
    Memorystore for Valkey のエンドポイントがここから IP を取る。
    ノード用サブネットを共用するとオートスケール時のノード IP とレンジを取り合うため分けている。
  EOT
  default     = "10.23.0.0/24"
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "コントロールプレーンへのアクセスを許可する CIDR。空リストの場合は制限なし (0.0.0.0/0 相当)"
  default     = []
}

# ---------------------------------------
# GKE cluster
# ---------------------------------------
variable "release_channel" {
  type        = string
  description = "GKE リリースチャネル (RAPID / REGULAR / STABLE / UNSPECIFIED)"
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "UNSPECIFIED"], var.release_channel)
    error_message = "release_channel は RAPID / REGULAR / STABLE / UNSPECIFIED のいずれか"
  }
}

variable "deletion_protection" {
  type        = bool
  description = "terraform destroy でクラスタを削除できないように保護するか"
  default     = false
}

variable "logging_components" {
  type        = list(string)
  description = <<-EOT
    Cloud Logging に送るコンポーネント。
    本リポジトリの OpenTelemetry Collector (platform/opentelemetry-collector) が
    filelog receiver でワークロードのコンテナログを収集し Cloud Logging に送るため、
    既定では ["SYSTEM_COMPONENTS"] に絞り GKE 側との二重集約 (と課金の二重発生) を避けている。
    OpenTelemetry Collector を使わずに GKE 標準のログ収集だけに任せたい場合は、
    ["SYSTEM_COMPONENTS", "WORKLOADS"] のように WORKLOADS を足すこと。
  EOT
  default     = ["SYSTEM_COMPONENTS"]
}

variable "monitoring_components" {
  type        = list(string)
  description = "Cloud Monitoring に送るコンポーネント"
  default     = ["SYSTEM_COMPONENTS"]
}

variable "enable_managed_prometheus" {
  type        = bool
  description = <<-EOT
    GKE のマネージド Prometheus を有効化するか。
    自前の OpenTelemetry Collector でメトリクスを収集する構成では、
    スクレイプ対象の重複とコスト増を避けるため既定で false にしている。
  EOT
  default     = false
}

# ---------------------------------------
# Node pool
# ---------------------------------------
variable "machine_type" {
  type        = string
  description = "ノードのマシンタイプ"
  default     = "e2-standard-4"
}

variable "node_count" {
  type        = number
  description = "ゾーンあたりの初期ノード数"
  default     = 1
}

variable "min_node_count" {
  type        = number
  description = "オートスケール時のゾーンあたり最小ノード数"
  default     = 1
}

variable "max_node_count" {
  type        = number
  description = "オートスケール時のゾーンあたり最大ノード数"
  default     = 3
}

variable "disk_size_gb" {
  type        = number
  description = "ノードのブートディスクサイズ (GB)"
  default     = 100
}

variable "disk_type" {
  type        = string
  description = "ノードのブートディスクタイプ"
  default     = "pd-balanced"
}

variable "spot" {
  type        = bool
  description = "Spot VM を使うか。検証環境ではコストを大きく下げられるが、ノードが予告なく回収される"
  default     = false
}

variable "node_labels" {
  type        = map(string)
  description = "ノードに付与する Kubernetes ラベル"
  default     = {}
}

# ---------------------------------------
# OpenTelemetry Collector
# ---------------------------------------
variable "create_otel_collector_service_account" {
  type        = bool
  description = "OpenTelemetry Collector 用の Google Service Account と Workload Identity バインディングを作成するか"
  default     = true
}

variable "otel_collector_namespace" {
  type        = string
  description = "OpenTelemetry Collector を配置する Kubernetes namespace"
  default     = "opentelemetry"
}

variable "otel_collector_ksa_name" {
  type        = string
  description = "OpenTelemetry Collector が使う Kubernetes ServiceAccount 名"
  default     = "otel-collector"
}

# ---------------------------------------
# Memorystore for Valkey
# ---------------------------------------
variable "create_memorystore_valkey" {
  type        = bool
  description = "Kong のセマンティック系プラグインがベクター DB として使う Memorystore for Valkey を作成するか"
  default     = true
}

variable "valkey_node_type" {
  type        = string
  description = "Valkey インスタンスのノードタイプ"
  default     = "SHARED_CORE_NANO"

  validation {
    condition     = contains(["SHARED_CORE_NANO", "STANDARD_SMALL", "HIGHMEM_MEDIUM", "HIGHMEM_XLARGE"], var.valkey_node_type)
    error_message = "valkey_node_type は SHARED_CORE_NANO / STANDARD_SMALL / HIGHMEM_MEDIUM / HIGHMEM_XLARGE のいずれか"
  }
}

variable "valkey_shard_count" {
  type        = number
  description = "Valkey インスタンスのシャード数。mode = CLUSTER_DISABLED では 1 のみ有効"
  default     = 1
}

variable "valkey_replica_count" {
  type        = number
  description = "シャードあたりのレプリカ数"
  default     = 0
}
