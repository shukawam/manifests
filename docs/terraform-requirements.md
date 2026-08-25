# `bootstrap/gke/` Terraform への追加要件

- 作成: 2026-08-25
- 対象: `bootstrap/gke/` の Terraform 一式（GKE Standard クラスタを構築する既存コード）
- 出典: `docs/superpowers/specs/2026-08-24-argocd-platform-design.md` §7 (Terraform 側への依存)
- 本書だけを渡された場合の前提:
  - Google Cloud プロジェクト: `gcp-fieldeng-dev` / リージョン: `asia-northeast1`
  - リソース接頭辞（`var.resource_prefix`）: `shukawam`（既存の `variables.tf` で定義済み。
    全リソース名は `format("%s-xxx", var.resource_prefix)` で組み立てる規約）
  - 公開ドメイン: `gke.shukawam.me`（`argocd.gke.shukawam.me` / `aigw.gke.shukawam.me`）
  - クラスタ名: `shukawam-gke`

このリポジトリでは Argo CD の App of Apps で GKE 上にプラットフォーム基盤（Argo CD 自身 /
cert-manager / External Secrets Operator / OpenTelemetry Operator / Kong Operator /
Kong Gateway / Kong AI Gateway）を構築する。Kubernetes マニフェスト側の実装は別セッションが
進めており、そちらが Terraform 側に要求する差分をこの文書にまとめる。

現状の `bootstrap/gke/` の Terraform には、以下がすべて存在しない。

---

## 1. 有効化する API

`apis.tf` の `locals.required_apis` に以下 2 つを追加する。

- `secretmanager.googleapis.com`
- `dns.googleapis.com`

既存の `google_project_service.this` リソース（`for_each = var.enable_apis ? toset(local.required_apis) : toset([])`）
がそのまま拾うため、リスト末尾に追加するだけでよい。

## 2. サービスアカウント（Workload Identity）

`service-accounts.tf` に、既存の `otel_collector` 用サービスアカウントと同じパターンで
以下 2 つの Google Service Account (GSA) を追加する。

| GSA (`account_id`) | 付与ロール | Workload Identity バインド先 (Kubernetes SA) |
| --- | --- | --- |
| `${resource_prefix}-external-secrets` （= `shukawam-external-secrets`） | `roles/secretmanager.secretAccessor` | `external-secrets/external-secrets` |
| `${resource_prefix}-cert-manager` （= `shukawam-cert-manager`） | `roles/dns.admin` | `cert-manager/cert-manager` |

各 GSA について、既存の `otel_collector` と同じ 3 点セットが必要:

1. `google_service_account` リソース本体
2. `google_project_iam_member`（上表のロールをプロジェクトに対して付与）
3. `google_service_account_iam_member`（`roles/iam.workloadIdentityUser` を
   `serviceAccount:${project_id}.svc.id.goog[<namespace>/<ksa_name>]` に付与）

Workload Identity バインド先の namespace / ServiceAccount 名（`external-secrets/external-secrets`,
`cert-manager/cert-manager`）はマニフェスト側の Helm values で固定する予定のため、
既存の `otel_collector_namespace` / `otel_collector_ksa_name` のような変数化は不要。
定数として埋め込んでよい。

### 2.1 output

以下 2 つの output を `outputs.tf` に追加する。既存の `otel_collector_ksa_annotation` と同じ形式
（`iam.gke.io/gcp-service-account=<email>`）にすること。

- `external_secrets_ksa_annotation`
- `cert_manager_ksa_annotation`

### 2.2 OpenTelemetry Collector 用 GSA は追加不要

既存の GSA `${resource_prefix}-otel-collector`（`service-accounts.tf` に定義済み）と、
そこに付与済みの `roles/monitoring.metricWriter` / `roles/cloudtrace.agent` /
`roles/logging.logWriter` で、Managed Service for Prometheus への書き込みまで含めて
権限は足りている。**この Terraform 要件では OTel Collector 側の変更は一切不要。**

## 3. 静的 IP アドレス

`google_compute_address` を **regional**（`region = "asia-northeast1"`）で 2 つ新規作成する。
L4 RBS（GKE の `type: LoadBalancer` が作るリージョナルパススルー Network Load Balancer）の
外部 NLB 用には `address_type = "EXTERNAL"` と `network_tier = "PREMIUM"` が必要。プロバイダの
既定値がたまたま両方とも一致するため省略しても動くが、担当者に推測させないよう明示的に
指定すること。

| リソース名 | 用途 |
| --- | --- |
| `${resource_prefix}-gke-gateway` （= `shukawam-gke-gateway`） | Kong Gateway (Gateway API) の DataPlane を公開する `type: LoadBalancer` Service 用 |
| `${resource_prefix}-gke-aigw` （= `shukawam-gke-aigw`） | Kong AI Gateway の DataPlane を公開する独立した `type: LoadBalancer` Service 用 |

**リージョナルであることが必須。** GKE の `type: LoadBalancer` Service が作るのはリージョナルな
パススルー Network Load Balancer であり、グローバル静的 IP は紐付けられない
（`google_compute_global_address` ではない）。

マニフェスト側は Kubernetes Service の annotation でこのアドレスの**名前**を参照する
（`networking.gke.io/load-balancer-ip-addresses: <アドレス名>`）。output に IP アドレス値自体は
不要だが、確認しやすいよう output しておくと良い（次項参照）。

### 3.1 output

- 2 つの IP アドレス自体（`google_compute_address.gateway.address` /
  `google_compute_address.aigw.address` の値）を output する。
  DNS レコードの設定確認や、annotation が効かない場合の手動フォールバック
  （§4 のフォールバック手順参照）に使う。

## 4. Cloud DNS

### 4.1 マネージドゾーン

`google_dns_managed_zone` を **パブリック**ゾーンとして作成する。

- DNS 名: `gke.shukawam.me.`（末尾のピリオドを含める）

`shukawam.me` 本体の権威 DNS は `01.dnsv.jp` / `02.dnsv.jp` にあり Cloud DNS 管理下にない。
`gke` サブドメインだけを Cloud DNS へ NS 委任する構成のため、`shukawam.me` 本体の設定には
一切触れない。NS 委任自体は Terraform の範囲外の手動作業（別文書で管理）であり、
この Terraform が用意するのはゾーンの `name_servers` 出力までで良い。

### 4.2 レコードセット

`google_dns_record_set` を 2 つ作成する。いずれも `type = "A"`、TTL は任意（既定値で可）。

| レコード名 | 種別 | 値 |
| --- | --- | --- |
| `*.gke.shukawam.me.` | A | `${resource_prefix}-gke-gateway` の IP アドレス |
| `aigw.gke.shukawam.me.` | A | `${resource_prefix}-gke-aigw` の IP アドレス |

ワイルドカードと個別レコードは共存できる。DNS の解決ではより具体的なレコードが優先されるため、
`aigw.gke.shukawam.me` は個別の A レコード（AI Gateway 用 IP）に、それ以外の
`*.gke.shukawam.me`（例: `argocd.gke.shukawam.me`）はワイルドカード経由で Gateway 用 IP に
解決される。

### 4.3 output

- `dns_zone_name_servers`: マネージドゾーンの `name_servers`（`dnsv.jp` 側での NS 委任に使う）

### 4.4 依存関係の順序（参考）

Cloud DNS ゾーンの作成 → NS 委任（手動、`dnsv.jp` 側の作業）→ cert-manager による証明書取得、
という順序があるため、`terraform apply` 後は必ず `dns_zone_name_servers` の出力値を
確認してから NS 委任作業に進む。NS 委任が済んでいないと、Kubernetes マニフェスト側の
`cert-manager-issuers` は同期できても証明書の発行が `Pending` のまま止まる
（これは Kubernetes マニフェスト側の既知動作であり、Terraform 側で対処することはない）。

### 4.5 IP annotation が効かない場合のフォールバック（参考、Terraform 側の対応は不要）

Kubernetes Service の `networking.gke.io/load-balancer-ip-addresses` annotation が実機で
機能しないことが判明した場合のフォールバックは 2 つ（いずれもマニフェスト側での対応）。

1. Terraform で A レコードを張るのをやめ、`kubectl get svc` で得た実際の IP を手で
   `google_dns_record_set` に設定し直す
2. external-dns を platform アプリとして追加し、`Gateway` / `Service` から自動で A レコードを
   同期させる（その場合 cert-manager 用に作成済みの `roles/dns.admin` ロールを持つ GSA を
   そのまま再利用できる）

この文書のスコープでは対応不要。参考情報として記載する。

---

## 5. `logging_components` の既定値変更（実装済み）

`variables.tf` の `logging_components` は既定値が `["SYSTEM_COMPONENTS", "WORKLOADS"]` だった。
一方このリポジトリの `platform/opentelemetry-collector/collector-node.yaml` の `filelog`
receiver が同じコンテナログを読み取り `googlecloud` exporter で Cloud Logging に送っている。
これを tfvars 側の上書きだけで避けようとすると、「`variables.auto.tfvars`（gitignore 対象の
実値ファイル）に誰かが 1 行足す」という**所有者のいない手順**が残ってしまう。忘れられれば
エラーも警告も出ないまま、GKE 標準のログ収集と OpenTelemetry Collector とで**同じログが
Cloud Logging に二重投入され、ログ取り込みの費用が倍になる。**

この本リポジトリでは `bootstrap/gke/` は常に本リポジトリの OpenTelemetry Collector と
セットで使われる前提のため、tfvars での上書きではなく **`variables.tf` の既定値そのものを
変更**して解決した。

```hcl
variable "logging_components" {
  ...
  default = ["SYSTEM_COMPONENTS"]
}
```

`variables.auto.tfvars.example` には既定値と同じ値をあえて明記していない（description に
理由が書いてある）。GKE 標準のログ収集にも Pod ワークロードのログを含めたい
（= OpenTelemetry Collector 側の収集をやめる、または両方に二重投入してよい）場合は、
`variables.auto.tfvars` で次のように上書きする。

```hcl
logging_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
```

---

## まとめ: 追加するリソース一覧

- `apis.tf`: `required_apis` に 2 API 追加
- `service-accounts.tf`: GSA 2 つ（`external-secrets` 用 / `cert-manager` 用）+ それぞれの
  IAM ロール付与 + Workload Identity バインディング
- 新規ファイル（例: `dns.tf` や `network.tf` への追記）: `google_compute_address` × 2
  （regional, `asia-northeast1`）
- 新規ファイル（例: `dns.tf`）: `google_dns_managed_zone` × 1、`google_dns_record_set` × 2
- `outputs.tf`: `external_secrets_ksa_annotation` / `cert_manager_ksa_annotation` /
  `dns_zone_name_servers` / Gateway 用 IP / AI Gateway 用 IP の計 5 つ（既存 output に追記）
- `variables.tf`: `logging_components` の既定値を `["SYSTEM_COMPONENTS"]` に変更
  （Cloud Logging と OpenTelemetry Collector によるログの二重集約を避ける。
  tfvars 側の上書きではなく既定値そのものを変更した）
