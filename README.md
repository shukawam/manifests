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
| cert-manager | Let's Encrypt のサーバ証明書発行 / OpenTelemetry Operator の webhook 証明書 / Kong AI Gateway の Konnect hybrid mTLS クラスタ証明書 |
| External Secrets Operator (ESO) | Google Cloud Secret Manager のシークレットをクラスタに同期する |
| OpenTelemetry Operator / Collector | クラスタのメトリクス・ログ・トレースを Google Cloud の可観測性基盤へ送る |
| Kong Ingress (`kong/ingress` Helm chart) | Kong Ingress Controller (KIC) による Gateway API の実装と、Kong Gateway データプレーンの両方を 1 chart で提供する（Kong Operator は廃止済み） |
| Kong Gateway (Gateway API) | クラスタの外部公開口。`https://argocd.gke.shukawam.me` を `HTTPRoute` で公開する |
| Kong AI Gateway | Konnect が管理する AI 用データプレーン。Kong Gateway 経由で `https://aigw.gke.shukawam.me` を公開する |
| PII Sanitizer (`kong/ai-pii/service`) | LLM リクエスト/レスポンス中の PII を検出・マスキングする Kong 製サービス。日英両方の spaCy モデルに対応 |

`bootstrap/` はクラスタと Argo CD が立ち上がるまでの、GitOps に乗せられない手前の 2 段
（`bootstrap/gke` = Terraform, `bootstrap/argocd` = Argo CD 初回インストール）。
`projects/` 以降はすべて Argo CD の管理下に入る。


> [!IMPORTANT]
> **AI Gateway だけは、DP クライアント証明書を Konnect に手で登録するまで機能しません。**
> cert-manager が発行した証明書が Konnect 側に未登録だと、データプレーンは
> `401` を繰り返して接続できません。手順は
> [`docs/known-issues.md` の 7](docs/known-issues.md) を参照。
> 証明書を更新したときも、その都度登録が必要です。
>
> Gateway API 経由の HTTPS 公開（`https://argocd.gke.shukawam.me`）は
> 2026-08-27 の Kong Operator 廃止・`kong/ingress` Helm chart への移行で解決済みです。

## 2. 実行順

```
1. bootstrap/gke     : terraform apply           → クラスタ + IAM + DNS ゾーン + 静的 IP
2. (手動・一度きり)  : dnsv.jp に gke の NS レコードを登録
3. (手動)            : gcloud container clusters get-credentials
4. (手動)            : Secret Manager に konnect-api-token を作成
5. (手動・一度きり)  : Auth0 にアプリを 2 つ作成 + Secret Manager に client secret を登録
6. bootstrap/argocd  : ./bootstrap.sh            → Argo CD + root app
7. (自動)            : App of Apps が残り全部を同期
8. (手動)            : kongctl で Konnect 側の設定を反映
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

Kong AI Gateway は `https://aigw.gke.shukawam.me` として、Gateway API
（`kong-gateway`）の `https` listener 経由で公開している（2026-08-28、独立
LoadBalancer での平文公開から移行。経緯は
[`docs/known-issues.md` の 9](docs/known-issues.md)）。TLS は Kong Gateway 側の
ワイルドカード証明書（`*.gke.shukawam.me`）で終端する。

背後には LLM プロバイダのクレデンシャルがあるため、**Konnect 側で key-auth などの認証
プラグインを必ず有効にすること。** Argo CD / Kubernetes 側にはこれを強制する仕組みがない
（Konnect 上の設定は `kongctl` による手動反映であり、GitOps の管理対象外）。

## 7. PII Sanitizer の imagePullSecret（手動、Secret Manager 登録のみ）

`platform/pii-sanitizer` は `docker.cloudsmith.io/kong/ai-pii/service`（プライベート
レジストリ）を使う。認証情報の値そのものは GitOps の管理対象外だが、クラスタへの
同期は ESO（`platform/pii-sanitizer/externalsecret.yaml`）が行うため、手動作業は
Secret Manager にシークレットを 1 個作るところまで。

```bash
kubectl create secret docker-registry pii-sanitizer-cloudsmith \
  --dry-run=client \
  --docker-server=docker.cloudsmith.io \
  --docker-username=<Cloudsmith のユーザー名> \
  --docker-password=<Cloudsmith のトークン> \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pii-sanitizer-dockerconfig.json

gcloud secrets create pii-sanitizer-cloudsmith-dockerconfigjson \
  --project gcp-fieldeng-dev --replication-policy automatic
gcloud secrets versions add pii-sanitizer-cloudsmith-dockerconfigjson \
  --project gcp-fieldeng-dev --data-file=/tmp/pii-sanitizer-dockerconfig.json
rm -f /tmp/pii-sanitizer-dockerconfig.json
```

このシークレットが存在しない状態で `pii-sanitizer` Application を同期すると、
`ExternalSecret` が解決できず Pod は `ImagePullBackOff` のまま止まる。

## 8. Argo CD の認証（Auth0 OIDC）

Argo CD のログインは Auth0 の OIDC に委譲している（Dex は使わない）。設定は
`platform/argo-cd/values.yaml` の `configs.cm.oidc.config` と `configs.rbac`。
ローカル `admin` アカウントは Auth0 側が壊れたときの break-glass として残してある。

### 8.1 Auth0 側（手動、一度きり）

前提として、カスタムドメイン `auth0.shukawam.me` が Branding → Custom Domains で
Verified になっていること。**Auth0 のカスタムドメインは social connection の
developer keys と併用できない**ため、Google ログインを使うなら Authentication →
Social → Google に自前の Google OAuth クライアントを設定しておく。

アプリケーションを 2 つ作る。`argocd` CLI は client secret を送れないので、Web UI 用
（confidential client）と CLI 用（public client）を分ける必要がある。

| | Web UI 用 | CLI 用 |
| --- | --- | --- |
| Name | `Argo CD (gke.shukawam.me)` | `Argo CD CLI` |
| Application Type | Regular Web Applications | Native |
| Allowed Callback URLs | `https://argocd.gke.shukawam.me/auth/callback` | `http://localhost:8085/auth/callback` |
| Allowed Logout URLs | `https://argocd.gke.shukawam.me` | （不要） |
| Allowed Web Origins | `https://argocd.gke.shukawam.me` | （不要） |
| 控える値 | Client ID / Client Secret | Client ID のみ |

CLI 側の `8085` は `argocd login --sso-port` の既定値。

2 つの Client ID は秘密情報ではないため、`values.yaml` に平文で書く
（`clientID` と `cliClientID`）。id_token の `aud` は経路によって Web 用 / CLI 用の
どちらかになるが、Argo CD は `allowedAudiences` 未指定時に両方を許可するため設定は要らない。

### 8.2 Secret Manager（手動、一度きり）

Client Secret のみ Secret Manager に置き、ESO でクラスタへ同期する
（`values.yaml` の `extraObjects` にある `ExternalSecret`）。

```bash
printf '%s' '<Web UI 用アプリの Client Secret>' \
  | gcloud secrets create argocd-auth0-client-secret \
      --project gcp-fieldeng-dev --replication-policy automatic --data-file=-
```

このシークレットが無いと `$argocd-auth0:clientSecret` が解決できず、Auth0 ログインだけが
失敗する（`admin` でのログインには影響しない）。フルブートストラップ時は ESO と
`ClusterSecretStore` が sync-wave 1 で立つまでこの `ExternalSecret` は解決を待つ。

### 8.3 権限

`configs.rbac` で `shukawam@gmail.com` のみ `role:admin`、それ以外は権限なし
（`policy.default: ""`）。ユーザーの識別に `sub` ではなく email クレームを使うため
`scopes: "[email]"` を指定している。

### 8.4 CLI からのログイン

```bash
argocd login argocd.gke.shukawam.me --grpc-web --sso
```

ブラウザが開いて Auth0 の認証画面に飛ぶ。`--grpc-web` が要る理由は 5 と同じ。

## 検証

全マニフェストの静的検証は `scripts/validate.sh` に集約している。CI・ローカルとも
これ 1 本を実行する。

```bash
./scripts/validate.sh
```

終了コード 0 なら妥当。実装が進むにつれ検証対象ディレクトリが増えていく設計のため、
未実装のコンポーネントは `skip (未作成)` と表示されるだけで FAIL にはならない。
