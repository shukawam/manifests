# manifests

GKE 上のプラットフォーム基盤を Argo CD の App of Apps パターンで GitOps 管理するリポジトリ。

- 対象リポジトリ: `https://github.com/shukawam/manifests.git`（`main` ブランチ）
- 対象クラスタ: `shukawam-gke`（Google Cloud プロジェクト `gcp-fieldeng-dev` / リージョン `asia-northeast1`）
- 公開ドメイン: `gke.shukawam.me`
- 設計の詳細: [`docs/superpowers/specs/2026-08-24-argocd-platform-design.md`](docs/superpowers/specs/2026-08-24-argocd-platform-design.md)

## 1. 何を作るリポジトリか

Argo CD の App of Apps で以下のプラットフォーム基盤を構築・自己管理する。

| コンポーネント | 役割 |
| --- | --- |
| Argo CD | GitOps コントローラ。ブートストラップ後は自分自身も Git 経由で管理する |
| cert-manager | Let's Encrypt のサーバ証明書発行 / OpenTelemetry Operator の webhook 証明書 / Kong Operator の CA・webhook 証明書 |
| External Secrets Operator (ESO) | Google Cloud Secret Manager のシークレットをクラスタに同期する |
| OpenTelemetry Operator / Collector | クラスタのメトリクス・ログ・トレースを Google Cloud の可観測性基盤へ送る |
| Kong Operator | Gateway API の実装と Konnect 連携の両方を担う |
| Kong Gateway (Gateway API) | クラスタの外部公開口。`https://argocd.gke.shukawam.me` を `HTTPRoute` で公開する |
| Kong AI Gateway | Konnect が管理する AI 用データプレーン。独立した LoadBalancer で `http://aigw.gke.shukawam.me:8000` を公開する |

`bootstrap/` はクラスタと Argo CD が立ち上がるまでの、GitOps に乗せられない手前の 2 段
（`bootstrap/gke` = Terraform, `bootstrap/argocd` = Argo CD 初回インストール）。
`projects/` 以降はすべて Argo CD の管理下に入る。

## 2. 実行順

```
1. bootstrap/gke     : terraform apply           → クラスタ + IAM + DNS ゾーン + 静的 IP
2. (手動・一度きり)  : dnsv.jp に gke の NS レコードを登録
3. (手動)            : gcloud container clusters get-credentials
4. (手動)            : Secret Manager に konnect-api-token を作成
5. bootstrap/argocd  : ./bootstrap.sh            → Argo CD + root app
6. (自動)            : App of Apps が残り全部を同期
7. (手動)            : kongctl で Konnect 側の設定を反映
```

手順 2 の NS 委任は、後段の cert-manager による証明書取得（DNS-01 チャレンジ）の前提になる。
委任が完了していないと `cert-manager-issuers` 以降は Argo CD 上 Synced になっても証明書が
`Pending` のまま止まる。手順ごとの詳細は
[設計ドキュメント §8](docs/superpowers/specs/2026-08-24-argocd-platform-design.md#8-前提となる手動手順)
を参照。

## 3. `bootstrap/gke` → `bootstrap/argocd` の実行方法

### 3.1 `bootstrap/gke`（Terraform）

```bash
cd bootstrap/gke
cp variables.auto.tfvars.example variables.auto.tfvars
# variables.auto.tfvars を編集（最低限 resource_prefix と project_id を確認）

gcloud auth application-default login

terraform init
terraform plan
terraform apply
```

適用後、以下の 2 つを必ず確認する。

```bash
# kubectl のコンテキストを取得
$(terraform output -raw get_credentials_command)

# NS 委任に使うネームサーバを確認し、dnsv.jp の管理画面で gke ホストの NS レコードとして登録する
terraform output dns_zone_name_servers
```

NS 委任後、反映を確認する。

```bash
dig +short NS gke.shukawam.me @1.1.1.1     # Cloud DNS のネームサーバが返れば成功
```

Konnect API トークンを Secret Manager に登録する（`printf` で末尾改行の混入を防ぐ）。

```bash
gcloud secrets create konnect-api-token --project gcp-fieldeng-dev --replication-policy automatic
printf '%s' "$KONNECT_TOKEN" | gcloud secrets versions add konnect-api-token \
  --project gcp-fieldeng-dev --data-file=-
```

Terraform 単体の詳細は [`bootstrap/gke/README.md`](bootstrap/gke/README.md) を参照。

### 3.2 `bootstrap/argocd`（Argo CD 初回インストール）

```bash
cd bootstrap/argocd
./bootstrap.sh
```

`bootstrap.sh` は `helm install` を薄くラップするだけで、宣言的にできることは一切やらない。
実行すると、`platform/argo-cd/values.yaml` を相対パスで直接読んで Argo CD をインストールし、
`projects/platform.yaml` と `root-app.yaml` を適用したうえで、初期 admin パスワードと
port-forward コマンドを案内して終了する。

インストール後、Argo CD は `apps/argo-cd.yaml`（自分自身と同じチャートバージョン・同じ values
ファイルを参照する Application）によって起動直後から自分自身を Synced と判定する。
**以後 `helm upgrade` は使わず、git（`platform/argo-cd/values.yaml`）の変更のみで管理する。**
`helm` が残す `sh.helm.release.v1.argocd.*` の Secret は害がないためそのまま残してよい。

## 4. フォークして使う場合の repoURL 一括置換

子 Application（`apps/*.yaml`）と `bootstrap/argocd/root-app.yaml` はいずれも
`repoURL: https://github.com/shukawam/manifests.git` をハードコードしている。
`bootstrap.sh` に `--repo-url` のようなオプションは**意図的に用意していない**
（ルートだけ差し替えると子 Application と整合しなくなるため）。フォークする場合はリポジトリ全体を
一括置換してから使うこと。

```bash
grep -rl 'github.com/shukawam/manifests' apps bootstrap \
  | xargs sed -i '' 's#github.com/shukawam/manifests#github.com/<you>/<repo>#g'
```

（GNU sed の場合は `sed -i` の直後の `''` は不要。macOS/BSD sed 前提のコマンド）

## 5. Argo CD へのアクセス（フォールバック）

`https://argocd.gke.shukawam.me` の公開が何らかの理由で機能しない場合（NS 委任未完了、
証明書 `Pending`、Kong Gateway 未同期など）に備えて、`kubectl port-forward` は**常時使える
フォールバック**として利用できる。

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

上記実行後、`http://localhost:8080` で Argo CD UI にアクセスできる。CLI から使う場合は
`--grpc-web` を付ける（Kong 経由の HTTP/1.1 転送では素の gRPC が通らないため）。

```bash
argocd login argocd.gke.shukawam.me --grpc-web
```

## 6. セキュリティ上の注意（Kong AI Gateway）

Kong AI Gateway（`http://aigw.gke.shukawam.me:8000`）は、LLM のストリーミング応答やタイムアウトに
関する不確実性を避けるため、独立した LoadBalancer で公開している。**この構成では
TLS を付けていない（平文 HTTP でインターネットに露出する）。**

背後には LLM プロバイダのクレデンシャルがあるため、**Konnect 側で key-auth などの認証
プラグインを必ず有効にすること。** Argo CD / Kubernetes 側にはこれを強制する仕組みがない
（Konnect 上の設定は `kongctl` による手動反映であり、GitOps の管理対象外）。

検証用途に限り、必要であれば Service の `loadBalancerSourceRanges` で送信元 IP を
絞ることも検討する。詳細は
[設計ドキュメント §6.10](docs/superpowers/specs/2026-08-24-argocd-platform-design.md#610-kong-ai-gateway)
を参照。

## 検証

全マニフェストの静的検証は `scripts/validate.sh` に集約している。CI・ローカルとも
これ 1 本を実行する。

```bash
./scripts/validate.sh
```

終了コード 0 なら妥当。実装が進むにつれ検証対象ディレクトリが増えていく設計のため、
未実装のコンポーネントは `skip (未作成)` と表示されるだけで FAIL にはならない。
