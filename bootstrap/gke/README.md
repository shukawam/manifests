# GKE Standard クラスタ (Terraform)

Google Cloud 上に **GKE Standard モード** のクラスタを構築する Terraform 一式。

## Autopilot ではなく Standard を使う理由

Autopilot はノードを GKE 側が完全管理するため、`hostPath` / `hostNetwork` / 特権コンテナを
伴う DaemonSet に強い制約がかかる。OpenTelemetry Collector をノードごとの DaemonSet として
配置し、kubelet やノードのファイルシステムからテレメトリを収集する構成には
ノードを自前で管理できる Standard モードが必要になる。

## 構成

| ファイル | 内容 |
| --- | --- |
| `versions.tf` | Terraform / プロバイダのバージョン制約 |
| `variables.tf` | 入力変数 |
| `apis.tf` | 必要な Google Cloud API の有効化 |
| `network.tf` | GKE 専用 VPC・サブネット (Pod / Service セカンダリレンジ付き) |
| `service-accounts.tf` | ノード用 SA、OpenTelemetry Collector 用 SA + Workload Identity |
| `gke.tf` | GKE Standard クラスタ本体とノードプール |
| `outputs.tf` | 出力値 |

作成されるリソースはすべて `format("%s-xxx", var.resource_prefix)` で命名されるため、
`resource_prefix` を変えるだけで同一プロジェクト内に別環境を並べられる。

| リソース | 名前 |
| --- | --- |
| VPC | `<prefix>-gke-vpc` |
| サブネット | `<prefix>-gke-subnet` |
| Pod セカンダリレンジ | `<prefix>-gke-pods` |
| Service セカンダリレンジ | `<prefix>-gke-services` |
| クラスタ | `<prefix>-gke` |
| ノードプール | `<prefix>-gke-node-pool` |
| ノード用 SA | `<prefix>-gke-node` |
| OTel Collector 用 SA | `<prefix>-otel-collector` |

## 使い方

```bash
cp variables.auto.tfvars.example variables.auto.tfvars
# terraform.tfvars を編集 (最低限 resource_prefix と project_id)

gcloud auth application-default login

terraform init
terraform plan
terraform apply
```

適用後、kubectl のコンテキストを取得する:

```bash
$(terraform output -raw get_credentials_command)
```

## 主なポイント

- **VPC-native**: Pod / Service はサブネットのセカンダリレンジから払い出される。
- **パブリッククラスタ**: `private_cluster_config` を指定していないため、手元から
  kubectl が直接通り、イメージ pull や外部への OTLP エクスポートもインターネットに
  直接出る。Cloud NAT は不要。コントロールプレーンへのアクセスを絞る場合は
  `master_authorized_networks` を指定する。
- **既定ノードプールの削除**: `remove_default_node_pool = true` とし、
  `google_container_node_pool` で明示的にノードプールを管理している。
- **最小権限のノード SA**: Compute Engine の既定 SA (Editor 相当) ではなく専用 SA を割り当て、
  `oauth_scopes` は `cloud-platform` にして実権限は IAM ロール側で絞る。
- **Workload Identity**: `GKE_METADATA` モードを有効化。Pod は鍵ファイルなしで
  Google Service Account を借用できる。
- **マネージド Prometheus は既定で無効** (`enable_managed_prometheus = false`)。
  自前の OpenTelemetry Collector と収集対象が重複してコストが増えるのを避けるため。
  GKE 側にも収集させたい場合は `true` にする。

## OpenTelemetry Collector を DaemonSet で配置する

`create_otel_collector_service_account = true` (既定) の場合、Collector 用の
Google Service Account と Workload Identity バインディングが作成される。
Kubernetes 側では次のように紐付ける。

```bash
kubectl create namespace opentelemetry

kubectl create serviceaccount otel-collector -n opentelemetry

kubectl annotate serviceaccount otel-collector -n opentelemetry \
  "$(terraform output -raw otel_collector_ksa_annotation)"
```

Helm chart (`open-telemetry/opentelemetry-collector`) を使う場合の最小 values:

```yaml
mode: daemonset

serviceAccount:
  create: false
  name: otel-collector

presets:
  # ノードの kubelet からメトリクスを収集
  kubeletMetrics:
    enabled: true
  # ノード上のコンテナログを収集 (hostPath を使うため Autopilot では不可)
  logsCollection:
    enabled: true
  kubernetesAttributes:
    enabled: true
```

namespace や ServiceAccount 名を変える場合は、Terraform 側の
`otel_collector_namespace` / `otel_collector_ksa_name` も合わせて変更する
(Workload Identity のバインディングがこの 2 つで決まるため)。

## 破棄

```bash
terraform destroy
```

`deletion_protection = false` が既定なのでそのまま削除できる。
本番用途では `true` にしておくこと。なお `apis.tf` で有効化した API は
`disable_on_destroy = false` としているため destroy しても無効化されない。
