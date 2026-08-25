# GKE プラットフォーム基盤 設計 (Argo CD App of Apps)

- 初版: 2026-08-24 / 改訂: 2026-08-25 (Kong Gateway による外部公開を追加)
- 対象リポジトリ: `https://github.com/shukawam/manifests.git` (public, ブランチ `main`)
- 対象クラスタ: `shukawam-gke` (project `gcp-fieldeng-dev`, region `asia-northeast1`)
- 公開ドメイン: `gke.shukawam.me` (Cloud DNS へ委任)

## 1. 目的

GKE 上に以下のプラットフォーム基盤を Argo CD の App of Apps パターンで構築する。

| コンポーネント | 役割 |
| --- | --- |
| Argo CD | GitOps コントローラ。ブートストラップ後は自分自身も管理する |
| cert-manager | 3 つの仕事を持つ: ①Let's Encrypt のサーバ証明書発行 ②OpenTelemetry Operator の webhook 証明書 ③Kong Operator の CA と webhook 証明書 |
| External Secrets Operator (ESO) | Google Cloud Secret Manager のシークレットをクラスタに同期する |
| OpenTelemetry Operator / Collector | クラスタのメトリクス・ログ・トレースを Google Cloud の可観測性基盤へ送る |
| Kong Operator | Gateway API の実装と、Konnect 連携の両方を担う |
| Kong Gateway (Gateway API) | クラスタの外部公開口。Argo CD を `HTTPRoute` で公開する |
| Kong AI Gateway | Konnect が管理する AI 用データプレーン。独立した LoadBalancer で公開する |

## 2. スコープ

### やること

- `bootstrap/argocd/bootstrap.sh` による Argo CD の初回インストール
- App of Apps のルート Application と、子 Application 群の定義
- 各コンポーネントの `values.yaml` / カスタムリソース
- ESO による Konnect API トークンの同期
- OpenTelemetry Collector の DaemonSet / Deployment 2 段構成と Google Cloud への出力
- Kong Operator による Gateway API 実装と、Argo CD の HTTPS 公開
- cert-manager + Cloud DNS DNS-01 によるワイルドカード証明書の自動取得
- Terraform 側 (`bootstrap/gke/`) に追加が必要な IAM / DNS / 静的 IP の明文化

### やらないこと

- **Konnect 上の API / プラグイン設定の同期**。`kongctl` による手動反映のままとし、Argo CD の管理対象にしない。
- Terraform の実装そのもの。別セッションの担当。本設計では必要な差分を要件として記述するにとどめる。
- **AI Gateway を Gateway API の背後に置くこと**。判断の経緯は §6.10 に記録する。
- external-dns。DNS レコードは Terraform が静的 IP に対して張るため不要。フォールバックとしてのみ §7.3 に記載。
- マルチクラスタ / マルチ環境のオーバーレイ。単一クラスタ前提とし、必要になった時点で `platform/` を kustomize 化する。

## 3. ディレクトリ構成

```
manifests/
├── README.md                          # 全体像と実行順
├── bootstrap/                         # GitOps に乗せられない手前の 2 段
│   ├── gke/                           # ① Terraform: GKE + IAM + DNS + 静的 IP
│   └── argocd/                        # ② Argo CD 本体の初回インストール
│       ├── bootstrap.sh
│       ├── root-app.yaml
│       └── README.md
├── projects/
│   └── platform.yaml                  # AppProject
├── apps/                              # App of Apps の子 Application 定義のみ
│   ├── projects.yaml                  # wave -2
│   ├── argo-cd.yaml                   # wave -1
│   ├── cert-manager.yaml              # wave  0
│   ├── external-secrets.yaml          # wave  0
│   ├── cert-manager-issuers.yaml      # wave  1
│   ├── secret-stores.yaml             # wave  1
│   ├── opentelemetry-operator.yaml    # wave  1
│   ├── kong-operator.yaml             # wave  1
│   ├── opentelemetry-collector.yaml   # wave  2
│   ├── kong-gateway.yaml              # wave  2
│   └── kong-ai-gateway.yaml           # wave  2
└── platform/                          # 実体。Helm のものは values.yaml だけ
    ├── argo-cd/values.yaml
    ├── cert-manager/values.yaml
    ├── cert-manager-issuers/
    │   ├── clusterissuer-letsencrypt-staging.yaml
    │   └── clusterissuer-letsencrypt-prod.yaml
    ├── external-secrets/values.yaml
    ├── secret-stores/clustersecretstore.yaml
    ├── opentelemetry-operator/values.yaml
    ├── opentelemetry-collector/
    │   ├── serviceaccount.yaml
    │   ├── rbac.yaml
    │   ├── collector-node.yaml
    │   └── collector-gateway.yaml
    ├── kong-operator/values.yaml
    ├── kong-gateway/
    │   ├── gatewayclass.yaml
    │   ├── gatewayconfiguration.yaml
    │   ├── certificate.yaml           # *.gke.shukawam.me
    │   ├── gateway.yaml
    │   ├── httproute-redirect.yaml   # :80 → :443
    │   └── httproute-argocd.yaml
    └── kong-ai-gateway/
        ├── externalsecret.yaml
        ├── konnect-api-auth.yaml
        ├── konnect-aigateway.yaml
        └── aigateway-dataplane.yaml
```

`bootstrap/` は「クラスタと Argo CD が立ち上がるまで、GitOps 化できない部分」を意味する。
`projects/` 以降はすべて Argo CD の管理下に入る。

## 4. 共通方針

### 4.1 Helm は multi-source Application で扱う

チャートは upstream の Helm リポジトリから直接引き、git 側には `values.yaml` だけを置く。
Kong Operator の「values.yaml だけを管理対象とする」という要件をそのまま満たせるため、
他コンポーネントも同じ形に揃える。

```yaml
spec:
  sources:
    - repoURL: https://charts.konghq.com
      chart: kong-operator
      targetRevision: 1.4.0-rc.1
      helm:
        valueFiles:
          - $values/platform/kong-operator/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
```

チャートを持たない Application (`cert-manager-issuers` / `secret-stores` /
`opentelemetry-collector` / `kong-gateway` / `kong-ai-gateway`) は単一 source の `path` 指定にする。

### 4.2 sync wave

子 Application 自体に `argocd.argoproj.io/sync-wave` を付ける。Argo CD は Application リソースの
ヘルスを判定できるため、前の wave が Healthy になるまで次の wave を開始しない。

| wave | Application | 依存理由 |
| --- | --- | --- |
| -2 | `projects` | AppProject が他のすべての前提 |
| -1 | `argo-cd` | 自己管理。他コンポーネントより先に落ち着かせる |
| 0 | `cert-manager` | 下の 3 つすべてが証明書を必要とする |
| 0 | `external-secrets` | CRD (`ClusterSecretStore` / `ExternalSecret`) を提供 |
| 1 | `cert-manager-issuers` | cert-manager の CRD が必要 |
| 1 | `secret-stores` | ESO の CRD が必要 |
| 1 | `opentelemetry-operator` | webhook 証明書に cert-manager が必要 |
| 1 | `kong-operator` | CA と webhook 証明書に cert-manager が必要 (§6.8) |
| 2 | `opentelemetry-collector` | OTel Operator の CRD が必要 |
| 2 | `kong-gateway` | Kong Operator の CRD と ClusterIssuer が必要 |
| 2 | `kong-ai-gateway` | Kong Operator の CRD と ESO が同期した Secret が必要 |

### 4.3 syncPolicy

全 Application 共通:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - ApplyOutOfSyncOnly=true
  retry:
    limit: 5
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 3m
```

`ServerSideApply=true` は必須。Kong Operator チャートは Gateway API を含む 60 本以上の CRD を
同梱しており、client-side apply では `metadata.annotations: Too long` (262144 バイト上限) で失敗する。
Argo CD 自己管理時に Helm が付けた field manager と衝突しないためにも要る。

`retry` を入れているのは、wave 内で CRD の確立と CR の適用が競合したときに自動で回復させるため。

唯一の例外は `kong-operator` で、この Application だけ `automated.prune: false` にする
(理由は §6.8)。それ以外はすべて上記のとおり。

### 4.4 リソース追跡方式

Argo CD の `application.resourceTrackingMethod` を `annotation` にする。既定の `label` 方式は
`app.kubernetes.io/instance` ラベルを書き換えるため、そのラベルを selector に使うチャートと衝突する。
ServerSideApply との併用でも annotation 方式が安全。

### 4.5 Helm チャートの `lookup` に依存しない

**このリポジトリで採用するすべてのチャートについて、`lookup` を使って自己署名証明書を
生成するオプションは使わない。** Argo CD は reconcile のたびに cluster 接続なしで
`helm template` を実行するため `lookup` は常に nil を返し、毎回新しい証明書が生成されて
恒久 OutOfSync になる。該当は 2 箇所で、いずれも cert-manager 連携に切り替える。

| チャート | 罠になるオプション | 採る設定 |
| --- | --- | --- |
| `opentelemetry-operator` | `admissionWebhooks.autoGenerateCert` | `admissionWebhooks.certManager.enabled: true` |
| `kong-operator` | `certificateAuthority` / `webhooks` の自己署名 (`templates/kong-operator-ca.yaml` が `lookup` + `genCA`) | 両方 `certManager.enabled: true` |

### 4.6 AppProject

`projects/platform.yaml` で `platform` プロジェクトを定義し、`sourceRepos` を
このリポジトリと使用する 5 つの Helm リポジトリ (argo-helm / jetstack /
external-secrets / open-telemetry / kong) だけに限定する。
destination は `https://kubernetes.default.svc` の全 namespace。
クラスタスコープリソース (CRD / ClusterRole / ClusterSecretStore / ClusterIssuer / GatewayClass) を
作るため `clusterResourceWhitelist` は `'*'` を許可する。

## 5. ブートストラップ

### 5.1 実行順

```
1. bootstrap/gke     : terraform apply           → クラスタ + IAM + DNS ゾーン + 静的 IP
2. (手動・一度きり)  : dnsv.jp に gke の NS レコードを登録  ← §8.1
3. (手動)            : gcloud container clusters get-credentials
4. (手動)            : Secret Manager に konnect-api-token を作成  ← §8.2
5. bootstrap/argocd  : ./bootstrap.sh            → Argo CD + root app
6. (自動)            : App of Apps が残り全部を同期
7. (手動)            : kongctl で Konnect 側の設定を反映
```

手順 2 の NS 委任は証明書取得 (DNS-01) の前提になる。委任が済んでいないと
`cert-manager-issuers` 以降は同期できても証明書が `Pending` のまま止まる。

### 5.2 `bootstrap/argocd/bootstrap.sh`

`helm install` を薄くラップするだけで、宣言的にできることは一切やらない。

```
1. 前提チェック (helm / kubectl / 現在の kube-context を表示して確認)
2. helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
3. helm upgrade --install argocd argo/argo-cd \
     --namespace argocd --create-namespace \
     --version 10.4.0 \
     --values ../../platform/argo-cd/values.yaml \
     --wait
4. kubectl apply -f ../../projects/platform.yaml
5. kubectl apply -f root-app.yaml
6. initial admin secret を表示し、port-forward のコマンドを案内して終了
```

オプションは `--dry-run` / `--help` のみ。`--repo-url` は**あえて用意しない**。
子 Application (`apps/*.yaml`) も同じ repoURL をハードコードしており、
ルートだけ差し替えても整合しないため。フォークして使う場合はリポジトリ全体を
一括置換する前提とし、その手順を `README.md` に明記する。

```bash
grep -rl 'github.com/shukawam/manifests' apps bootstrap \
  | xargs sed -i '' 's#github.com/shukawam/manifests#github.com/<you>/<repo>#g'
```

**values は `platform/argo-cd/values.yaml` を相対パスで直接読む。**
`bootstrap/argocd/` 側に values を複製しない。ブートストラップ時と Argo CD 自己管理後で
values が二重管理になるのを防ぐのが目的。

### 5.3 自己管理への引き継ぎ

`apps/argo-cd.yaml` が同じチャートバージョン・同じ values ファイルを参照するため、
Argo CD は起動直後から自分自身を Synced と判定する。
`helm` が残す `sh.helm.release.v1.argocd.*` Secret は害がないのでそのまま残す
(README に「以後 helm upgrade は使わず git を変更する」と明記)。

### 5.4 `bootstrap/argocd/root-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy: (§4.3 と同じ)
```

`recurse: false` にして `apps/` 直下のファイルだけを拾う。
子 Application の実体は `platform/` にあり、`apps/` には Application 定義しか置かない。

## 6. コンポーネント別設計

チャートバージョンはすべて 2026-08-25 時点で `helm search repo` により実在を確認済み。

### 6.1 Argo CD

- チャート: `argo/argo-cd` `10.4.0` (Argo CD v3.5.1)
- namespace: `argocd`
- 公開 URL: `https://argocd.gke.shukawam.me`
- values の要点:
  - `global.domain: argocd.gke.shukawam.me`
  - `configs.params."server.insecure": true` — **TLS は Kong で終端する**。
    Argo CD 自身は平文 HTTP を話す
  - `configs.cm.url: https://argocd.gke.shukawam.me` — リダイレクト先の生成に使われる
  - `configs.cm."application.resourceTrackingMethod": annotation`
  - `dex.enabled: false` / `notifications.enabled: false` — 使わないものは落とす
  - `server.service.type: ClusterIP` / `server.ingress.enabled: false`
    (公開は `HTTPRoute` で行うため、チャートの Ingress 機能は使わない)
  - `controller` / `repoServer` に控えめな resources を設定

**gRPC の扱い**: `argocd` CLI は UI と同じポートで gRPC を話す。Kong で TLS を終端して
HTTP/1.1 で転送する構成では素の gRPC は通らないため、**CLI は `--grpc-web` を使う**。

```bash
argocd login argocd.gke.shukawam.me --grpc-web
```

gRPC 用に別ホスト名を立てる案もあるが、証明書とルートが増えるだけなので採らない。

### 6.2 cert-manager

- チャート: `jetstack/cert-manager` `v1.21.1`
- namespace: `cert-manager`
- values の要点:

```yaml
crds:
  enabled: true
  keep: true
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: shukawam-cert-manager@gcp-fieldeng-dev.iam.gserviceaccount.com
```

Workload Identity で Cloud DNS を操作するため、コントローラの ServiceAccount に annotation を付ける。

### 6.3 cert-manager-issuers

`ClusterIssuer` を 2 つ置く。まず staging で疎通を確認してから prod に切り替える運用にする
(Let's Encrypt の prod はレート制限が厳しく、DNS 委任のミスで簡単に枯らせるため)。

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: shuhei.kawamura@konghq.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudDNS:
            project: gcp-fieldeng-dev
            # Workload Identity を使うため serviceAccountSecretRef は書かない
```

DNS-01 を選んだ理由: HTTP-01 は Kong Gateway 自身が健全であることを前提にするため、
Gateway が壊れると証明書の更新もできなくなる。DNS-01 は Kong に依存せず、
かつワイルドカード証明書 (`*.gke.shukawam.me`) を取得できる。

### 6.4 External Secrets Operator

- チャート: `external-secrets/external-secrets` `2.9.0` (ESO v2.9.0)
- namespace: `external-secrets`
- API グループは **`external-secrets.io/v1`** (v2 系で v1 が storage version)。`v1beta1` は使わない。
- values の要点:

```yaml
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: shukawam-external-secrets@gcp-fieldeng-dev.iam.gserviceaccount.com
```

  ESO はコントローラ / webhook / cert-controller の 3 つの ServiceAccount を作るが、
  Secret Manager にアクセスするのはコントローラだけなので、そこにだけ annotation を付ける。

### 6.5 secret-stores

`platform/secret-stores/clustersecretstore.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: gcp-secret-manager
spec:
  provider:
    gcpsm:
      projectID: gcp-fieldeng-dev
```

`auth` を明示しない。ESO コントローラの Pod が Workload Identity 経由で取得する
Application Default Credentials がそのまま使われる。
`auth.workloadIdentity` を書くと ESO が KSA トークンを自前で交換する経路になり、
`serviceaccounts/token` の RBAC など前提が増えるため採らない。

`ClusterSecretStore` にしている理由: 同期先が `kong` namespace であり、
今後 LLM の API キーなどを別 namespace に配る可能性があるため。

### 6.6 OpenTelemetry Operator

- チャート: `open-telemetry/opentelemetry-operator` `0.122.0` (Operator 0.158.0)
- namespace: `opentelemetry-operator-system`
- values の要点:

```yaml
admissionWebhooks:
  certManager:
    enabled: true          # 既定。§4.5 のとおり autoGenerateCert は使わない
manager:
  collectorImage:
    repository: otel/opentelemetry-collector-contrib
```

`manager.collectorImage` を contrib に向けることで、`OpenTelemetryCollector` CR 側で
毎回 `image:` を指定しなくてよくなる。Google 系 exporter (`googlecloud` /
`googlemanagedprometheus`) は contrib ディストリビューションにしか入っていない。

### 6.7 OpenTelemetry Collector

Operator の `OpenTelemetryCollector` CR を 2 つ作る。ServiceAccount は
Terraform が Workload Identity をバインド済みの **`opentelemetry` namespace の `otel-collector`** を
両方で共有する。

```
[Pod / ノード]
     |
     |  (a) kubeletstats / hostmetrics / filelog
     v
otel-node (DaemonSet)
     |
     |  OTLP gRPC
     v
otel-gateway (Deployment, replicas: 1)  <-- (b) アプリからの OTLP トレースもここで受ける
     |                                  <-- (c) k8s_cluster でクラスタ全体のリソース状態を収集
     +--> googlemanagedprometheus  --> Cloud Monitoring
     +--> googlecloud (traces)     --> Cloud Trace
     +--> googlecloud (logs)       --> Cloud Logging
```

#### `platform/opentelemetry-collector/serviceaccount.yaml`

`opentelemetry` namespace と `otel-collector` ServiceAccount を定義し、
`iam.gke.io/gcp-service-account: shukawam-otel-collector@gcp-fieldeng-dev.iam.gserviceaccount.com`
を付与する。Terraform の `otel_collector_ksa_annotation` 出力と一致させる。

#### `platform/opentelemetry-collector/rbac.yaml`

Operator は CR ごとに ServiceAccount を作れるが RBAC は作らない。
`serviceAccount:` を明示指定する構成では **自前で ClusterRole / ClusterRoleBinding が必要**。
`k8sattributes` / `k8s_cluster` / `kubeletstats` が必要とする以下を許可する。

- core: `pods`, `namespaces`, `nodes`, `nodes/stats`, `nodes/proxy`, `services`, `endpoints`,
  `events`, `replicationcontrollers`, `resourcequotas`, `persistentvolumes`,
  `persistentvolumeclaims` (get / list / watch)
- core の **subresource** も必須: `namespaces/status`, `nodes/spec`, `pods/status`,
  `replicationcontrollers/status`。`k8sclusterreceiver` の公式 ClusterRole が baseline 要件として
  挙げている。欠けると informer が実行時に 403 を受け、Argo CD は Synced/Healthy のまま
  クラスタメトリクスだけが静かに欠落する
- `apps`: `daemonsets`, `deployments`, `replicasets`, `statefulsets`
- `batch`: `jobs`, `cronjobs`
- `autoscaling`: `horizontalpodautoscalers`

#### `otel-node` (mode: daemonset)

- receivers
  - `kubeletstats`: `auth_type: serviceAccount`, `endpoint: ${env:K8S_NODE_NAME}:10250`,
    `insecure_skip_verify: true`, metric_groups は node / pod / container / volume
  - `hostmetrics` は**使わない**。`/hostfs` のマウントと `root_path` が無い状態では
    cpu / load / memory / network は Collector コンテナ自身の cgroup 視点の値を返し、
    resources.limits に制限された Pod の使用量が「ノードのメトリクス」として記録される。
    ノードの cpu / memory / network は `kubeletstats` の node メトリクスグループが
    正しく提供するため、そちらに一本化する (失うのは load average のみ)。
    ホストのルートファイルシステム全体をコンテナにマウントする権限昇格も避けられる。
  - `filelog`: `/var/log/pods/*/*/*.log` を読み、`container` operator で
    containerd のフォーマットを解析。Collector 自身のログは `exclude` で除外し、
    ログのループを防ぐ
- processors: `memory_limiter` → `k8sattributes` → `resourcedetection` (`env`, `gcp`) → `batch`
  - **`k8sattributes` の `pod_association` は `k8s.pod.uid` と (`k8s.namespace.name`, `k8s.pod.name`) で
    関連付ける。`k8s.pod.ip` と `from: connection` は使わない。** `filelog` の `container` operator は
    Pod 名 / UID / namespace を付けるが IP は付けず、`kubeletstats` はローカルの pull で
    接続コンテキストを持たないため、IP や connection では 1 件もマッチせず
    `k8s.deployment.name` / `k8s.node.name` が付かない。
- exporters: `otlp` (`otel-gateway-collector.opentelemetry.svc.cluster.local:4317`, `tls.insecure: true`)
- 環境変数 `K8S_NODE_NAME` を `fieldRef: spec.nodeName` で注入
- volume: hostPath `/var/log` を read-only でマウント。
  `securityContext.runAsUser: 0` — `/var/log/pods` の読み取りに必要。
  Terraform 側が Autopilot ではなく Standard を選んでいるのはまさにこの構成のため。

#### `otel-gateway` (mode: deployment, replicas: 1)

- receivers
  - `otlp`: gRPC 4317 / HTTP 4318。node collector とアプリケーションの両方から受ける
  - `k8s_cluster`: クラスタ全体の Deployment / Pod / Node の状態。
    **重複計上を避けるためレプリカは 1 に固定する**
- processors: `memory_limiter` → `k8sattributes` → `resourcedetection` (`env`, `gcp`) → `batch`
- exporters
  - `googlemanagedprometheus`: `project: gcp-fieldeng-dev` — メトリクス
  - `googlecloud`: `project: gcp-fieldeng-dev` — トレースとログ
- pipelines
  - `metrics`: [`otlp`, `k8s_cluster`] → `googlemanagedprometheus`
  - `traces`: [`otlp`] → `googlecloud`
  - `logs`: [`otlp`] → `googlecloud`

メトリクスを `googlemanagedprometheus` にする理由: `googlecloud` exporter は全メトリクスを
`custom.googleapis.com/...` のカスタムメトリクス記述子として登録するため、
kubeletstats + hostmetrics + k8s_cluster の規模では記述子の上限とコストに当たる。
Terraform が `enable_managed_prometheus = false` にしているのは GKE 側の**収集**を止める設定であり、
Managed Service for Prometheus の**保存先**は有効なのでこの exporter は動作する。

`resourcedetection` の `gcp` detector が `cloud.availability_zone` / `k8s.cluster.name` を、
`k8sattributes` が `k8s.namespace.name` / `k8s.pod.name` / `k8s.container.name` を埋めるため、
`googlemanagedprometheus` exporter が `prometheus_target` モニタリング対象リソースへ
自動でマッピングできる。追加の `transform` は不要。

### 6.8 Kong Operator

- チャート: `kong/kong-operator` `1.4.0-rc.1` (appVersion 2.3.0-rc.2)
- namespace: `kong`
- `platform/kong-operator/values.yaml`:

```yaml
image:
  tag: "2.3.0-rc.2"
env:
  ENABLE_CONTROLLER_KONNECT: true
  ENABLE_CONTROLLER_AIGATEWAYDATAPLANE: true
global:
  webhooks:
    options:
      certManager:
        enabled: true
  certificateAuthority:
    options:
      certManager:
        enabled: true
```

**キーの階層に注意。** このチャートでは `webhooks` / `certificateAuthority` は
**`global:` 配下にしか存在しない** (`helm show values kong/kong-operator --version 1.4.0-rc.1`
の 113 行目以降で確認)。トップレベルに置くと Helm は黙って無視し、`genCA` が走り続ける。
本設計の初版はこれをトップレベルに書いており誤りだった。実装時の冪等性検証
(同じ values で 2 回レンダリングして diff を取る) で発覚した。

前半は Konnect が出力したセットアップコマンドの `--set` をそのまま落としたもの。
チャートバージョンもコマンドの `--version 1.4.0-rc.1` に合わせて固定する。

後半の cert-manager 連携は §4.5 の対応。既定値は両方 `false` で、その場合
`templates/kong-operator-ca.yaml` が

```
{{ if not (lookup "v1" "Secret" $caSecretNamespace $caSecretName) }}
{{ $ca := genCA "Kong Operator CA" 3650 }}
```

という実装になっており、Argo CD 上では reconcile のたびに新しい CA が生成される。
チャートの values コメント自身も `It is recommended to enable cert-manager integration for
production use` と書いている。

CRD はチャートのサブチャート (`ko-crds` 1.1.0 / `gwapi-standard-crds` 1.6.1) として同梱されており、
Gateway API 標準 CRD (`gatewayclasses` / `gateways` / `httproutes` / `grpcroutes` …) と
`gatewayconfigurations` / `controlplanes` / `dataplanes` /
`aigatewaydataplanes.aigateway.konghq.com` / `konnectaigateways.konnect.konghq.com` /
`konnectapiauthconfigurations.konnect.konghq.com` を含むことを確認済み。
**CRD 用の別 Application は作らない。**

注意点: `ko-crds.keep: true` は Helm の `resource-policy` であり Argo CD には効かない。
CRD の誤削除を避けるため、この Application だけ `syncPolicy.automated.prune: false` にする。

### 6.9 Kong Gateway (Gateway API)

クラスタの外部公開口。Kong Operator が同じ CRD セットで提供する Gateway API 実装を使う。

```
                          静的IP #1 / *.gke.shukawam.me
                                   ↓
[Internet] → Kong DataPlane (:80 → :443 redirect, :443 TLS 終端)
                   └─ HTTPRoute  argocd.gke.shukawam.me → argocd-server.argocd:80
```

#### `gatewayclass.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
spec:
  controllerName: konghq.com/gateway-operator
  parametersRef:
    group: gateway-operator.konghq.com
    kind: GatewayConfiguration
    name: kong
    namespace: kong
```

#### `gatewayconfiguration.yaml`

apiVersion は **`gateway-operator.konghq.com/v2beta1`**。`v1beta1` も served だが
`deprecated: true` かつ `storage: false` のため使わない。

```yaml
spec:
  # controlPlaneOptions は書かない。v2beta1 の controlPlaneOptions は
  # cache / configDump / controllers / dataplaneSync / featureGates /
  # gatewayDiscovery / ingressClass / konnect / objectFilters / translation /
  # watchNamespaces の 11 個のみで、deployment は存在しない (v1beta1 にはある)。
  # structural schema のため未知フィールドは黙って prune され、書いても効かない。
  dataPlaneOptions:
    deployment:
      replicas: 2
    network:
      services:
        ingress:
          type: LoadBalancer
          annotations:
            cloud.google.com/l4-rbs: "enabled"
            networking.gke.io/load-balancer-ip-addresses: shukawam-gke-gateway
```

**この CRD は `spec.loadBalancerIP` を公開していない** (`ingress` 直下は `annotations` /
`externalTrafficPolicy` / `internalTrafficPolicy` / `labels` / `name` /
`trafficDistribution` / `type` / PDB 系のみ)。したがって静的 IP の固定は
**annotation 経由しか手段がない**。上記の GKE annotation が Kong Operator が生成する
Service に対して期待どおり効くかは実機確認が必要 (§9 のリスク表に記載)。

#### `certificate.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gke-shukawam-me
  namespace: kong
spec:
  secretName: gke-shukawam-me-tls
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod
  commonName: "*.gke.shukawam.me"
  dnsNames:
    - "*.gke.shukawam.me"
    - "gke.shukawam.me"
```

cert-manager の Gateway API 統合 (`ExperimentalGatewayAPISupport` フィーチャーゲート) は使わず、
`Certificate` を明示的に定義する。フィーチャーゲートを増やさずに済み、
証明書の状態を単独で確認できるため。

#### `gateway.yaml`

`kong` namespace。listener は 2 つ。

- `http` (:80, HTTP) — `httproute-redirect.yaml` が `*.gke.shukawam.me` を受け、
  `RequestRedirect` フィルタ (`scheme: https`, `statusCode: 301`) で :443 へ飛ばす
- `https` (:443, HTTPS) — `tls.mode: Terminate`, `certificateRefs: [gke-shukawam-me-tls]`

両方の `allowedRoutes.namespaces.from: All` にする。`HTTPRoute` を `argocd` など
他 namespace に置けるようにするため。

#### `httproute-argocd.yaml`

**`HTTPRoute` は `argo-cd` の Application ではなく `kong-gateway` の Application に置く。**
`argo-cd` は wave -1 で、その時点では Gateway API の CRD がまだ存在しないため。
ルーティング定義を Gateway の隣にまとめることで、公開経路が 1 箇所で読めるという副次的な利点もある。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
    - name: kong
      namespace: kong
      sectionName: https
  hostnames:
    - argocd.gke.shukawam.me
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
      timeouts:
        request: 60s
        backendRequest: 60s
```

`argocd` namespace の `HTTPRoute` が `kong` namespace の `Gateway` を参照するため、
`Gateway` 側で `allowedRoutes.namespaces.from: All` が必要 (上記で対応済み)。
`backendRefs` は同一 namespace なので `ReferenceGrant` は不要。

### 6.10 Kong AI Gateway

Konnect が出力したマニフェストを、Secret を ESO 生成に差し替えた上でそのまま GitOps 化する。
Application 内の sync wave で `kubectl apply` の順序を再現する。

| wave | ファイル | リソース |
| --- | --- | --- |
| 0 | `externalsecret.yaml` | `ExternalSecret` → `konnect-api-auth-secret` |
| 1 | `konnect-api-auth.yaml` | `KonnectAPIAuthConfiguration` |
| 2 | `konnect-aigateway.yaml` | `KonnectAIGateway` |
| 3 | `aigateway-dataplane.yaml` | `AIGatewayDataPlane` |

#### 公開方法: 独立した LoadBalancer

`AIGatewayDataPlane` は普通の Deployment + Service なので、`type: ClusterIP` にして
§6.9 の `Gateway` に `HTTPRoute` でぶら下げることは技術的に可能で、
LB と証明書を 1 つに集約できる。**それでも独立した LB を採用する。**

理由は Kong の前段に Kong を置いたときの 2 つのリスク。

1. **レスポンスバッファリング** — Kong の `response_buffering` は既定 `true` で、
   このままだと LLM の SSE ストリーミングがバッファされて壊れる。KIC が `HTTPRoute` に対して
   `konghq.com/response-buffering` アノテーションを honor するかは KIC のバージョン依存で、
   検証なしには保証できない。
2. **タイムアウト** — 長い LLM 応答が外側 Kong の読み取りタイムアウトで切れる。
   `HTTPRoute.rules[].timeouts.backendRequest` で伸ばせるが、1 と組み合わせた
   挙動の確認が要る。

AI Gateway は本構成の主役であり、ここに検証コストと不確実性を持ち込む価値が薄いと判断した。
将来ぶら下げたくなった場合は `network.services.ingress.type` を `ClusterIP` に変え、
`HTTPRoute` を 1 本足すだけで移行できる。

```yaml
network:
  services:
    ingress:
      type: LoadBalancer
      annotations:
        cloud.google.com/l4-rbs: "enabled"
        networking.gke.io/load-balancer-ip-addresses: shukawam-gke-aigw
      ports:
        - name: http
          port: 8000
          targetPort: 8000
```

公開 URL は `http://aigw.gke.shukawam.me:8000`。**TLS は付かない。**
AI Gateway の設定は Konnect 側にあり、証明書を Kubernetes から差し込む経路がないため。

> **セキュリティ上の注意 (README に明記する)**: この構成では AI Gateway が
> 平文 HTTP でインターネットに露出する。背後には LLM プロバイダのクレデンシャルがあるため、
> Konnect 側で key-auth などの認証プラグインを必ず有効にすること。
> 検証用途に限り、必要なら `master_authorized_networks` と同様に
> Service の `loadBalancerSourceRanges` で送信元を絞ることも検討する。

#### `externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: konnect-api-auth
  namespace: kong
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: gcp-secret-manager
  target:
    name: konnect-api-auth-secret
    creationPolicy: Owner
    template:
      metadata:
        labels:
          konghq.com/credential: konnect
          konghq.com/secret: "true"
  data:
    - secretKey: token
      remoteRef:
        key: konnect-api-token
```

`target.template.metadata.labels` で Konnect が要求する 2 つのラベルを再現する。
ESO は `template` を指定しないとラベルを引き継がないため、ここが最重要ポイント。

#### 残り 2 ファイル

いただいたマニフェストと同一。`KonnectAPIAuthConfiguration` の `serverURL` は
`us.api.konghq.com`、`KonnectAIGateway` は `source: Mirror` で
`mirror.konnect.id: 87ffec73-4403-49c8-bc99-81dc47fce093`、
`AIGatewayDataPlane` は `kong/kong-ai-gateway:2.0.2` を replicas 1。

## 7. Terraform 側への依存 (`bootstrap/gke/` の担当セッションへ)

現状の Terraform には以下がすべて存在しない。この節をそのまま別セッションへ渡す。

### 7.1 API

`apis.tf` の `required_apis` に追加:

- `secretmanager.googleapis.com`
- `dns.googleapis.com`

### 7.2 サービスアカウント

| GSA | ロール | Workload Identity バインド先 |
| --- | --- | --- |
| `${resource_prefix}-external-secrets` | `roles/secretmanager.secretAccessor` | `external-secrets/external-secrets` |
| `${resource_prefix}-cert-manager` | `roles/dns.admin` | `cert-manager/cert-manager` |

output: `external_secrets_ksa_annotation`, `cert_manager_ksa_annotation`
(いずれも `iam.gke.io/gcp-service-account=<email>` 形式)。

OpenTelemetry Collector 側は既存の GSA `${resource_prefix}-otel-collector` と
`roles/monitoring.metricWriter` / `roles/cloudtrace.agent` / `roles/logging.logWriter` で
Managed Service for Prometheus への書き込みまで足りるため **追加は不要**。

### 7.3 静的 IP

`google_compute_address` を **regional (`asia-northeast1`)** で 2 つ。

| 名前 | 用途 |
| --- | --- |
| `${resource_prefix}-gke-gateway` | Kong Gateway (Gateway API) の DataPlane LB |
| `${resource_prefix}-gke-aigw` | Kong AI Gateway の DataPlane LB |

**リージョナルであることが必須。** `type: LoadBalancer` の Service が作るのは
リージョナルなパススルー NLB であり、グローバル IP は紐付けられない。

マニフェスト側は Service の annotation で**アドレス名**を参照する (§6.9 / §6.10)。
この annotation が効かないことが実機で判明した場合のフォールバックは 2 つ。

1. Terraform で A レコードを張るのをやめ、`kubectl get svc` で得た IP を手で登録する
2. external-dns を platform アプリとして追加し、`Gateway` / `Service` から
   自動で A レコードを同期させる (cert-manager と同じ `roles/dns.admin` を再利用できる)

### 7.4 Cloud DNS

- `google_dns_managed_zone`: **パブリック**ゾーン、DNS 名 `gke.shukawam.me.`
- `google_dns_record_set`:
  - `*.gke.shukawam.me.` A → `${resource_prefix}-gke-gateway` の IP
  - `aigw.gke.shukawam.me.` A → `${resource_prefix}-gke-aigw` の IP
- output: ゾーンの `name_servers` (委任に使う)

ワイルドカードと個別レコードは共存できる。DNS の解決では**より具体的なレコードが優先**されるため、
`aigw.gke.shukawam.me` は個別の A レコードに、それ以外の `*.gke.shukawam.me` は
Gateway の IP に解決される。

### 7.5 依存関係の順序

Cloud DNS ゾーンの作成 → NS 委任 (手動) → 証明書取得 (cert-manager) という順序があるため、
Terraform の output に「次に何をすべきか」を含めておくと事故が減る。

## 8. 前提となる手動手順

### 8.1 `gke.shukawam.me` の NS 委任 (一度きり)

当初 `shukawam.lab` が候補に挙がったが、**`.lab` は委任された TLD ではない**
(`dig SOA lab.` が無応答。実在 TLD は `dig SOA land.` のように応答する)。
インターネットから解決できないため Let's Encrypt が証明書を発行できず、採用しなかった。

`shukawam.me` の権威 DNS は `01.dnsv.jp` / `02.dnsv.jp` にあり、Cloud DNS ではない。
サブゾーンだけを委任することで、`shukawam.me` 本体の運用に手を入れずに済む。

```bash
terraform -chdir=bootstrap/gke output dns_zone_name_servers
```

出力された 4 本のネームサーバを、`dnsv.jp` の管理画面で `gke` ホストの **NS レコード**として登録する。
反映後に確認:

```bash
dig +short NS gke.shukawam.me @1.1.1.1     # Cloud DNS のネームサーバが返れば成功
```

これが通るまで cert-manager の DNS-01 チャレンジは成功しない。

### 8.2 Konnect API トークンの登録

```bash
gcloud secrets create konnect-api-token --project gcp-fieldeng-dev --replication-policy automatic
printf '%s' "$KONNECT_TOKEN" | gcloud secrets versions add konnect-api-token \
  --project gcp-fieldeng-dev --data-file=-
```

`printf` を使うのは末尾の改行がトークンに混入するのを防ぐため。

### 8.3 Konnect 側の設定反映

`kongctl` で行う。Argo CD は関与しない。

## 9. 想定される失敗と対処

| 事象 | 原因 | 対処 |
| --- | --- | --- |
| CRD 適用が `Too long` で失敗 | client-side apply の annotation 上限 | `ServerSideApply=true` (§4.3 で全 Application に設定済み) |
| `kong-operator` が毎回 OutOfSync | チャートの CA テンプレートが `lookup` を使う | `certificateAuthority` / `webhooks` の `certManager.enabled: true` (§6.8) |
| `opentelemetry-operator` が毎回 OutOfSync | `autoGenerateCert` の再生成 | `admissionWebhooks.certManager.enabled: true` (§6.6) |
| `Certificate` が `Pending` のまま | NS 委任が未完了 / `dns.admin` が無い | §8.1 の `dig` で委任を確認。cert-manager のログで DNS-01 の失敗理由を見る |
| **LB の IP が静的 IP にならない** | GKE の annotation が Kong Operator 生成の Service で効かない | §7.3 のフォールバック 1 or 2。**実装時に最初に検証すべき項目** |
| `HTTPRoute` が `Accepted` にならない | `allowedRoutes` / `parentRefs` の namespace 不一致 | `kubectl describe httproute -n argocd argocd` の status を見る |
| `argocd` CLI が接続できない | gRPC が Kong を通らない | `--grpc-web` を付ける (§6.1) |
| `kong-ai-gateway` が wave 0 で止まる | Secret Manager にトークンが無い / IAM 未設定 | `kubectl describe externalsecret -n kong` で ESO の condition を確認 |
| メトリクスが Cloud Monitoring に出ない | Workload Identity の annotation 不一致 | KSA の annotation と Terraform 出力を突き合わせる |
| `otel-node` がログを読めない | `/var/log/pods` の権限 | `securityContext.runAsUser: 0` を確認 |
| Argo CD が自分自身で OutOfSync | ブートストラップと `apps/argo-cd.yaml` の values / version 不一致 | 両者が同じファイル・同じチャートバージョンを見ていることを確認 |
| **Argo CD の UI に入れなくなった** | Gateway / HTTPRoute / 証明書を壊した | `kubectl port-forward svc/argocd-server -n argocd 8080:80` を常時フォールバックとして README に記載 |

## 10. 検証方法

```bash
# 1. 全 Application が Synced / Healthy
kubectl get applications -n argocd

# 2. ESO が Secret を作れているか
kubectl get externalsecret,secret -n kong
kubectl get clustersecretstore gcp-secret-manager -o jsonpath='{.status.conditions}'

# 3. Collector が起動しているか
kubectl get opentelemetrycollector -n opentelemetry
kubectl logs -n opentelemetry -l app.kubernetes.io/name=otel-gateway-collector --tail=50

# 4. Gateway と証明書
kubectl get gateway,httproute -A
kubectl get certificate,certificaterequest -n kong
kubectl get svc -n kong    # EXTERNAL-IP が静的 IP と一致するか  ← 最重要

# 5. DNS と TLS
dig +short NS gke.shukawam.me @1.1.1.1
dig +short argocd.gke.shukawam.me @1.1.1.1
curl -sI https://argocd.gke.shukawam.me | head -1
argocd login argocd.gke.shukawam.me --grpc-web

# 6. Kong の状態
kubectl get -n kong konnectapiauthconfiguration,konnectaigateway,aigatewaydataplane -o wide

# 7. Google Cloud 側への到達確認
gcloud logging read 'resource.type="k8s_container"' --project gcp-fieldeng-dev --limit 5
# Cloud Monitoring: Metrics Explorer で prometheus_target / kubeletstats 由来の系列を確認
# Cloud Trace: AI Gateway に 1 リクエスト流してからトレース一覧を確認
```

すべてのマニフェストは実装後に以下で構文と描画を検証する。

```bash
helm template <release> <repo>/<chart> --version <ver> -f platform/<component>/values.yaml
kubectl apply --dry-run=client -f platform/<component>/
```
