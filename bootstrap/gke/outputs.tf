output "cluster_name" {
  value       = google_container_cluster.gke.name
  description = "GKE Standard クラスタ名"
}

output "cluster_location" {
  value       = google_container_cluster.gke.location
  description = "クラスタのロケーション (リージョン)"
}

output "cluster_endpoint" {
  value       = google_container_cluster.gke.endpoint
  description = "コントロールプレーンのエンドポイント"
}

output "cluster_ca_certificate" {
  value       = google_container_cluster.gke.master_auth[0].cluster_ca_certificate
  description = "クラスタの CA 証明書 (base64)"
  sensitive   = true
}

output "workload_identity_pool" {
  value       = google_container_cluster.gke.workload_identity_config[0].workload_pool
  description = "Workload Identity プール"
}

output "network_name" {
  value       = google_compute_network.gke.name
  description = "GKE 専用 VPC 名"
}

output "subnet_name" {
  value       = google_compute_subnetwork.gke.name
  description = "ノード用サブネット名"
}

output "node_service_account_email" {
  value       = google_service_account.gke_node.email
  description = "ノードに割り当てたサービスアカウント"
}

output "otel_collector_service_account_email" {
  value       = var.create_otel_collector_service_account ? google_service_account.otel_collector[0].email : null
  description = "OpenTelemetry Collector が Workload Identity で借用する Google Service Account"
}

output "otel_collector_ksa_annotation" {
  value = var.create_otel_collector_service_account ? format(
    "iam.gke.io/gcp-service-account=%s",
    google_service_account.otel_collector[0].email,
  ) : null
  description = "OpenTelemetry Collector の Kubernetes ServiceAccount に付与するアノテーション"
}

output "external_secrets_service_account_email" {
  value       = google_service_account.external_secrets.email
  description = "External Secrets Operator が Workload Identity で借用する Google Service Account"
}

output "external_secrets_ksa_annotation" {
  value = format(
    "iam.gke.io/gcp-service-account=%s",
    google_service_account.external_secrets.email,
  )
  description = "External Secrets Operator の Kubernetes ServiceAccount に付与するアノテーション"
}

output "cert_manager_service_account_email" {
  value       = google_service_account.cert_manager.email
  description = "cert-manager が Workload Identity で借用する Google Service Account"
}

output "cert_manager_ksa_annotation" {
  value = format(
    "iam.gke.io/gcp-service-account=%s",
    google_service_account.cert_manager.email,
  )
  description = "cert-manager の Kubernetes ServiceAccount に付与するアノテーション"
}

output "kong_ai_gateway_service_account_email" {
  value       = google_service_account.kong_ai_gateway.email
  description = "kong-ai-gateway が Workload Identity で借用する Google Service Account"
}

output "kong_ai_gateway_ksa_annotation" {
  value = format(
    "iam.gke.io/gcp-service-account=%s",
    google_service_account.kong_ai_gateway.email,
  )
  description = "kong-ai-gateway の Kubernetes ServiceAccount に付与するアノテーション"
}

output "gateway_ip_address" {
  value       = google_compute_address.gateway.address
  description = "Kong Gateway (Gateway API) の DataPlane を公開する Service 用の静的外部 IP アドレス"
}

output "dns_zone_name_servers" {
  value       = google_dns_managed_zone.gke.name_servers
  description = "gke.shukawam.me ゾーンのネームサーバ一覧 (dnsv.jp 側での NS 委任に使う)"
}

output "get_credentials_command" {
  value = format(
    "gcloud container clusters get-credentials %s --region %s --project %s",
    google_container_cluster.gke.name,
    google_container_cluster.gke.location,
    var.project_id,
  )
  description = "kubectl のコンテキストを取得するコマンド"
}

output "valkey_host" {
  value       = var.create_memorystore_valkey ? google_memorystore_instance.valkey[0].endpoints[0].connections[0].psc_auto_connection[0].ip_address : null
  description = "Memorystore for Valkey の PSC エンドポイント IP (Kong のセマンティック系プラグインの redis.host に入れる)"
}

output "valkey_port" {
  value       = var.create_memorystore_valkey ? google_memorystore_instance.valkey[0].endpoints[0].connections[0].psc_auto_connection[0].port : null
  description = "Memorystore for Valkey の PSC エンドポイントポート"
}
