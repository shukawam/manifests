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
| `network.tf` | GKE 専用 VPC・サブネット (Pod / Service セカンダリレンジ付き)、Private Service Connect 用サブネット |
| `service-accounts.tf` | ノード用 SA、OpenTelemetry Collector 用 SA、External Secrets Operator 用 SA、cert-manager 用 SA (いずれも Workload Identity) |
| `static-ip.tf` | Kong Gateway / Kong AI Gateway 用のリージョナル静的外部 IP |
| `dns.tf` | gke.shukawam.me のパブリックゾーンと A レコード (ワイルドカード / aigw) |
| `gke.tf` | GKE Standard クラスタ本体とノードプール |
| `memorystore.tf` | Memorystore for Valkey と、その到達に必要な PSC のサービス接続ポリシー |
| `outputs.tf` | 出力値 |

作成されるリソースはすべて `format("%s-xxx", var.resource_prefix)` で命名されるため、
`resource_prefix` を変えるだけで同一プロジェクト内に別環境を並べられる。

| リソース | 名前 |
| --- | --- |
| VPC | `<prefix>-gke-vpc` |
| サブネット | `<prefix>-gke-subnet` |
| PSC 用サブネット | `<prefix>-psc-subnet` |
| Pod セカンダリレンジ | `<prefix>-gke-pods` |
| Service セカンダリレンジ | `<prefix>-gke-services` |
| クラスタ | `<prefix>-gke` |
| ノードプール | `<prefix>-gke-node-pool` |
| ノード用 SA | `<prefix>-gke-node` |
| OTel Collector 用 SA | `<prefix>-otel-collector` |
| External Secrets Operator 用 SA | `<prefix>-external-secrets` |
| cert-manager 用 SA | `<prefix>-cert-manager` |
| Kong Gateway 用静的 IP | `<prefix>-gke-gateway` |
| Kong AI Gateway 用静的 IP | `<prefix>-gke-aigw` |
| Cloud DNS マネージドゾーン | `<prefix>-gke-zone` (`gke.shukawam.me.`) |
| PSC サービス接続ポリシー | `<prefix>-memorystore` |
| Valkey インスタンス | `<prefix>-valkey` |

## 使い方

```bash
cp variables.auto.tfvars.example variables.auto.tfvars
# variables.auto.tfvars を編集 (最低限 resource_prefix と project_id)

gcloud auth application-default login

terraform init
terraform plan
terraform apply
```

適用後、kubectl のコンテキストを取得する:

```bash
$(terraform output -raw get_credentials_command)
```

## Memorystore for Valkey

Kong のセマンティック系プラグイン (`ai-semantic-cache` など) がベクター DB として参照する
Valkey インスタンス。`create_memorystore_valkey = false` にすると一式作られない。

Memorystore for Valkey は Private Service Connect の自動接続でしか到達できず、消費者側 VPC に
`service_class = gcp-memorystore` のサービス接続ポリシーが無いとインスタンスの作成自体が失敗する。
そのため `google_network_connectivity_service_connection_policy` が実質的な前提リソースになっている。
エンドポイントの IP はポリシーが指すサブネットから割り当てられるが、ノード用サブネットを共用すると
オートスケールで増えるノード IP とレンジを取り合うため、`psc_subnet_cidr` (既定 `10.23.0.0/24`) で
専用サブネットを切っている。

VPC 内からしか到達できない検証用インスタンスなので AUTH も TLS も掛けていない。どちらも immutable で、
後から有効化するとインスタンスの再作成になる。同様に `mode = CLUSTER_DISABLED` (単一ノード) にしているのは、
Kong 側の redis 設定を `host` / `port` だけで済ませるため。CLUSTER モードでは `cluster_nodes` の列挙が必要になる。

接続先は output で取得し、Konnect 側のプラグイン設定 (`kongctl`) に手で書き写す。

```bash
terraform output valkey_host
terraform output valkey_port
```

Pod からの疎通確認:

```bash
kubectl run -it --rm valkey-check --image redis:7-alpine --restart Never -- \
  redis-cli -h "$(terraform output -raw valkey_host)" -p "$(terraform output -raw valkey_port)" PING
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

## External Secrets Operator / cert-manager の Workload Identity

External Secrets Operator 用 SA (`roles/secretmanager.secretAccessor`) と
cert-manager 用 SA (Cloud DNS の DNS-01 チャレンジ専用カスタムロール) は、
バインド先の namespace / ServiceAccount 名 (`external-secrets/external-secrets`,
`cert-manager/cert-manager`) を Terraform 側で定数として埋め込んでいる
(マニフェスト側の Helm values で固定される前提のため、otel_collector のような
namespace / ksa_name 変数はない)。Kubernetes 側の ServiceAccount には
それぞれの annotation を付与する。

```bash
kubectl annotate serviceaccount external-secrets -n external-secrets \
  "$(terraform output -raw external_secrets_ksa_annotation)"

kubectl annotate serviceaccount cert-manager -n cert-manager \
  "$(terraform output -raw cert_manager_ksa_annotation)"
```

cert-manager 用 SA には `roles/dns.admin` ではなく、このディレクトリで定義した
カスタムロール (`google_project_iam_custom_role.cert_manager_dns`) を付与している。
`dns.admin` はプロジェクト内の無関係なゾーン (別クラスタの private zone を含む) まで
操作できてしまうため、DNS-01 チャレンジに必要な最小権限に絞っている。

## Cloud DNS ゾーンと NS 委任

`dns.tf` が作成する `google_dns_managed_zone.gke` は `gke.shukawam.me` 用のパブリック
ゾーンで、`shukawam.me` 本体 (01.dnsv.jp / 02.dnsv.jp 管理) には一切触れない。
apply 後、以下でネームサーバを確認し、dnsv.jp 側で `gke` ホストの NS レコードとして
手動登録する (この NS 委任自体は Terraform の範囲外)。

```bash
terraform output dns_zone_name_servers
```

NS 委任が完了するまでは cert-manager の DNS-01 チャレンジが解決できず、
`Certificate` は `Pending` のまま止まる (Kubernetes マニフェスト側の既知動作)。

`google_dns_record_set` の TTL は 60 秒と短めにしている。静的 IP の
`networking.gke.io/load-balancer-ip-addresses` annotation が実機で効かなかった場合に
A レコードを手動で張り替えて反復する可能性があるため、反映待ちを短くする狙い。

## 破棄

```bash
terraform destroy
```

`deletion_protection = false` が既定なのでそのまま削除できる。
本番用途では `true` にしておくこと。なお `apis.tf` で有効化した API は
`disable_on_destroy = false` としているため destroy しても無効化されない。
