# Kong Operator から Helm Chart への移行 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kong Operator を廃止し、Kong Gateway を `kong/ingress`、AI Gateway を `kong/kong-ai-gateway` の Helm Chart で導入する。KIC のイメージタグを固定して、ルーティング全停止の不具合を解消する。

**Architecture:** Gateway API のリソース（`Gateway` / `HTTPRoute` / `Certificate`）は資産として維持し、`GatewayClass` の接続先だけを KIC に差し替える。Gateway API の CRD は `kong/ingress` に同梱されないため専用 Application を追加し、KIC より前の sync wave に置く。旧 CR を先に削除し、オペレータを最後に消す。

**Tech Stack:** `kong/ingress` 0.24.0 / `kong/kong-ai-gateway` 0.1.0 / KIC 3.5.13 / Gateway API v1 / Argo CD 10.4.0

**Spec:** `docs/superpowers/specs/2026-08-27-kong-helm-migration-design.md`

## Global Constraints

- リポジトリ: `https://github.com/shukawam/manifests.git` / ブランチ `main`
- Google Cloud プロジェクト: `gcp-fieldeng-dev` / クラスタ `shukawam-gke` / 接頭辞 `shukawam`
- 公開ドメイン: `gke.shukawam.me`（Argo CD は `argocd.gke.shukawam.me`）
- 静的 IP: Gateway 用 `shukawam-gke-gateway` (35.221.95.244) / AI Gateway 用 `shukawam-gke-aigw` (34.84.176.193)
- **KIC のイメージタグは `3.5.13` に固定する。`3.5` の浮動タグは使わない。** `3.5.5` 未満を引くと移行前と同じ全停止に戻る
- チャートは固定: `kong/ingress` `0.24.0` / `kong/kong-ai-gateway` `0.1.0`
- 全 Application の `syncOptions` に `ServerSideApply=true` を必ず入れる
- 各タスクの最後は `./scripts/validate.sh` が終了コード 0 になってからコミットする
- コメント・コミットメッセージは日本語

### 実測で確定済みの値（推測しないこと）

| 項目 | 値 | 確認方法 |
| --- | --- | --- |
| `GatewayClass.spec.controllerName` | `konghq.com/kic-gateway-controller` | KIC 公式ドキュメント |
| Gateway API CRD の同梱 | **`kong/ingress` は同梱しない**（24 CRD 中 0 件） | `helm template --include-crds` |
| CRD の導入順序 | **KIC の起動より前**に CRD が存在する必要がある | KIC 公式ドキュメント |
| KIC のイメージ | `controller.ingressController.image.tag` | 上書きしてレンダリング確認 |
| Gateway のイメージ | `gateway.image.tag` | 同上 |
| proxy Service | `gateway.proxy.type` / `gateway.proxy.annotations` → `<release>-gateway-proxy` | 同上 |
| AI GW proxy Service | `proxy.type` / `proxy.annotations` → `<release>-kong-ai-gateway-proxy` | 同上 |
| AI GW の Konnect 接続 | `env.cluster_control_plane` / `env.cluster_server_name` / `env.cluster_telemetry_endpoint` / `env.cluster_telemetry_server_name` / `env.cluster_cert` / `env.cluster_cert_key` / `env.konnect_mode` / `env.cluster_mtls` | `helm show values` |

### 現在の Konnect の実値（`shukawam-gke` で稼働中の実測値）

| 項目 | 値 |
| --- | --- |
| AI Gateway ID | `87ffec73-4403-49c8-bc99-81dc47fce093`（Konnect 上の表示名 `zdf-ai-gateway`） |
| 設定エンドポイント | `fa722e22fb.us.cp.konghq.com` |
| テレメトリエンドポイント | `fa722e22fb.us.tp.konghq.com` |
| Konnect API | `https://us.api.konghq.com` |

---

## File Structure

| ファイル | 責務 |
| --- | --- |
| `apps/gateway-api-crds.yaml` | 新規。Gateway API 標準 CRD を導入する Application（wave 0） |
| `platform/gateway-api-crds/` | 新規。CRD マニフェストの取得元を定義 |
| `apps/kong-ingress.yaml` | 新規。`kong/ingress` の multi-source Application（wave 1） |
| `platform/kong-ingress/values.yaml` | 新規。KIC のタグ固定と proxy の静的 IP |
| `apps/kong-gateway.yaml` | 既存流用。Gateway API リソース（wave 2） |
| `platform/kong-gateway/gatewayclass.yaml` | 書き換え。`controllerName` を KIC に、`parametersRef` を削除 |
| `platform/kong-gateway/gatewayconfiguration.yaml` | **削除**（オペレータ専用 CRD） |
| `platform/kong-gateway/{certificate,gateway,httproute-*}.yaml` | 無変更 |
| `apps/kong-ai-gateway.yaml` | 書き換え。チャート + git の multi-source（wave 2） |
| `platform/kong-ai-gateway/values.yaml` | 新規。Konnect 接続設定と静的 IP |
| `platform/kong-ai-gateway/externalsecret.yaml` | 維持 |
| `platform/kong-ai-gateway/{konnect-api-auth,konnect-aigateway,aigateway-dataplane}.yaml` | **削除**（オペレータ専用 CRD） |
| `apps/kong-operator.yaml` / `platform/kong-operator/` | **削除** |
| `scripts/validate.sh` | `render_targets` の更新 |

---

## Task 1: Gateway API CRD の Application を追加する

**このタスクを最初に行う理由**: `kong/ingress` は Gateway API CRD を同梱せず（実測: 24 CRD 中 0 件）、
KIC は**起動時点で CRD が存在しないと Gateway API リソースを一切 reconcile しない**。
CRD の供給元は現在 Kong Operator のサブチャートであり、オペレータを消すと消える。
先に代替を用意しないと `platform/kong-gateway/` が全滅する。

**Files:**
- Create: `apps/gateway-api-crds.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: AppProject `platform`、既存 `apps/*.yaml` の `syncPolicy` の形
- Produces: `gatewayclasses` / `gateways` / `httproutes` / `grpcroutes` / `referencegrants` 等の
  Gateway API 標準 CRD。Task 2 の KIC と Task 4 の Gateway API リソースが依存する

- [ ] **Step 1: 現在導入されている Gateway API CRD のバージョンを確認する**

移行前後でバージョンが変わると既存の `Gateway` / `HTTPRoute` が壊れる可能性があるため、
**今入っているものと同じバージョンを選ぶ**。

```bash
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
kubectl get crd -o name | grep gateway.networking.k8s.io | wc -l
```

出力されたバンドルバージョン（例 `v1.3.0`）を控える。以降のステップで使う。

- [ ] **Step 2: `apps/gateway-api-crds.yaml` を書く**

`targetRevision` は Step 1 で確認したバンドルバージョンに合わせること。
下記の `v1.3.0` は仮の値であり、**必ず Step 1 の実測値に置き換える**。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-api-crds
  namespace: argocd
  annotations:
    # KIC より前に導入する必要がある。KIC は起動時点で CRD が無いと
    # Gateway API リソースを一切 reconcile しない (公式ドキュメント)。
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/kubernetes-sigs/gateway-api
    targetRevision: v1.3.0
    path: config/crd/standard
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      # CRD を誤って消すと Gateway / HTTPRoute が巻き添えで消える
      prune: false
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

- [ ] **Step 3: `projects/platform.yaml` の `sourceRepos` に GitHub の Gateway API リポジトリを追加する**

AppProject が許可していない source は Argo CD が拒否する。

```yaml
  sourceRepos:
    - https://github.com/shukawam/manifests.git
    - https://github.com/kubernetes-sigs/gateway-api
    - https://argoproj.github.io/argo-helm
    - https://charts.jetstack.io
    - https://charts.external-secrets.io
    - https://open-telemetry.github.io/opentelemetry-helm-charts
    - https://charts.konghq.com
```

- [ ] **Step 4: 検証**

Run: `./scripts/validate.sh; echo $?`
Expected: `0`

**この時点ではまだ適用しない。** Task 5 まで書き上げてから一括で同期する。
先に CRD だけ入れても害はないが、順序の検証を Task 5 で通しで行う。

- [ ] **Step 5: コミット**

```bash
git add apps/gateway-api-crds.yaml projects/platform.yaml
git commit -m "feat: Gateway API CRD の Application を追加

kong/ingress は Gateway API CRD を同梱しない (実測: 24 CRD 中 0 件)。
KIC は起動時点で CRD が無いと Gateway API リソースを reconcile しないため、
KIC より前の wave で導入する。現在の供給元は Kong Operator のサブチャートで、
オペレータ削除に伴い消えるため代替が必要。"
```

---

## Task 2: `kong/ingress` の Application と values を追加する

**Files:**
- Create: `apps/kong-ingress.yaml`
- Create: `platform/kong-ingress/values.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: Gateway API CRD（Task 1）、AppProject `platform`
- Produces:
  - KIC（`GatewayClass` の `controllerName: konghq.com/kic-gateway-controller` を処理する）
  - Kong Gateway の proxy Service `kong-ingress-gateway-proxy`（静的 IP `shukawam-gke-gateway`）
  - Task 4 の `GatewayClass` がこの KIC に紐付く

- [ ] **Step 1: `platform/kong-ingress/values.yaml` を書く**

```yaml
# kong/ingress は薄いラッパで、実体は kong サブチャートを
# controller (KIC) と gateway (Kong Gateway) の 2 エイリアスで
# 2 回インスタンス化する構成になっている。

controller:
  ingressController:
    image:
      # ★ 浮動タグ (3.5) を使わないこと。
      # KIC 3.4.0 で混入した SNI 生成の不具合により、TLS 証明書を付けた Gateway が
      # 宣言的設定の投入を全件失敗させ、その Gateway のルーティングが全停止する
      # (docs/known-issues.md 参照)。3.5.5 の
      # "Fixed an issue with SNI generation in dbless mode. (#7853)" で修正済み。
      # Kong Operator ではこのバージョンを選べず、本移行の目的そのものが
      # 「KIC のバージョンを自分で決めること」である。パッチまで固定する。
      tag: "3.5.13"

gateway:
  proxy:
    type: LoadBalancer
    annotations:
      # Terraform が予約した静的 IP を固定する。この annotation が GKE で
      # 実際に機能することは実機検証済み (35.221.95.244 が割り当たる)。
      cloud.google.com/l4-rbs: "enabled"
      networking.gke.io/load-balancer-ip-addresses: shukawam-gke-gateway
```

- [ ] **Step 2: values が実際に効くことをレンダリングで確認する**

推測でキーを書いていないことを、毎回この方法で確かめる。

```bash
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update kong >/dev/null
helm template kong-ingress kong/ingress --version 0.24.0 -n kong \
  -f platform/kong-ingress/values.yaml > /tmp/ki.yaml

# KIC のタグ
grep -o "kong/kubernetes-ingress-controller:[0-9.]*" /tmp/ki.yaml | sort -u
# 期待: kong/kubernetes-ingress-controller:3.5.13

# proxy Service に annotation が乗っているか
python3 -c "
import yaml
for d in yaml.safe_load_all(open('/tmp/ki.yaml')):
    if isinstance(d,dict) and d.get('kind')=='Service' and 'proxy' in d['metadata']['name']:
        print(d['metadata']['name'], d['spec'].get('type'),
              (d['metadata'].get('annotations') or {}).get('networking.gke.io/load-balancer-ip-addresses'))
"
# 期待: kong-ingress-gateway-proxy LoadBalancer shukawam-gke-gateway
```

**期待値と違ったら先へ進まず報告すること。** values のキーが無視されている可能性がある。

- [ ] **Step 3: `apps/kong-ingress.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong-ingress
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://charts.konghq.com
      chart: ingress
      targetRevision: 0.24.0
      helm:
        valueFiles:
          - $values/platform/kong-ingress/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kong
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

- [ ] **Step 4: `scripts/validate.sh` の `render_targets` に追加する**

`platform/kong-operator/values.yaml` の行を残したまま、新しい行を追加する
（削除は Task 5 で行う）。

```
  "platform/kong-ingress/values.yaml|kong/ingress|0.24.0|kong"
```

- [ ] **Step 5: 検証してコミット**

Run: `./scripts/validate.sh; echo $?`
Expected: `0`、かつ `OK   helm template kong/ingress` が出ること

```bash
git add apps/kong-ingress.yaml platform/kong-ingress/values.yaml scripts/validate.sh
git commit -m "feat: kong/ingress の Application を追加し KIC を 3.5.13 に固定

KIC 3.4.0 で混入した SNI 生成の不具合を避けるため、パッチバージョンまで固定する。
浮動タグ 3.5 は使わない。Helm でバージョンを選べることが本移行の目的である。"
```

---

## Task 3: AI Gateway を Helm Chart へ移行する

**このタスクの難所**: オペレータ版は DP のクライアント証明書を自動生成し Konnect へ登録していた。
Helm 版は**証明書を自分で用意し、Konnect へ登録するのも自分**になる。
証明書が Konnect に登録されていないと DP は 401 で接続できない。

**Files:**
- Create: `platform/kong-ai-gateway/values.yaml`
- Modify: `apps/kong-ai-gateway.yaml`
- Delete: `platform/kong-ai-gateway/konnect-api-auth.yaml`
- Delete: `platform/kong-ai-gateway/konnect-aigateway.yaml`
- Delete: `platform/kong-ai-gateway/aigateway-dataplane.yaml`
- Keep: `platform/kong-ai-gateway/externalsecret.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: `ClusterSecretStore gcp-secret-manager`、Konnect の実値（Global Constraints 参照）
- Produces: AI Gateway の proxy Service `kong-ai-gateway-kong-ai-gateway-proxy`（静的 IP `shukawam-gke-aigw`）

- [ ] **Step 1: 現在の DP クライアント証明書を退避する**

オペレータが生成した証明書は Konnect に登録済みで、DP はそれで接続している。
**同じ証明書を使い続ければ Konnect への再登録が不要**になる。

```bash
kubectl get secret aigw-dp-kong-tg7wq -n kong -o yaml > /tmp/aigw-dp-cert-backup.yaml
kubectl get secret aigw-dp-kong-tg7wq -n kong -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -fingerprint -sha256
```

指紋を控える。Step 6 で Konnect 側と突き合わせる。

**Secret 名はオペレータが生成したランダム接尾辞を含む。** 実際の名前を
`kubectl get secret -n kong -l konghq.com/secret=true` で確認してから使うこと。

- [ ] **Step 2: 証明書を Argo CD 管理下に移すか判断して報告する**

この Secret はオペレータが所有しており、オペレータ削除で消える可能性がある。
選択肢は 2 つ。**どちらを採るかはコントローラに報告して裁定を仰ぐこと。**

- (a) 退避した Secret を固定名（例 `aigw-dp-cert`）でリポジトリに入れず、
  クラスタに手で作り直して values から参照する。証明書は git に入らないが手作業が残る
- (b) cert-manager の自己署名 `Certificate` で新規に発行し、Konnect へ登録し直す。
  宣言的になるが Konnect への登録手順が増える

**証明書の秘密鍵を git にコミットしてはならない。** これは選択肢に含めない。

- [ ] **Step 3: `platform/kong-ai-gateway/values.yaml` を書く**

Step 2 の裁定を反映した上で書く。`clusterCaSecretName` と証明書 Secret 名は裁定次第。

```yaml
# Konnect の hybrid 接続設定。オペレータ版では KonnectAIGateway CR が
# エンドポイントを解決していたが、Helm 版では values に直接書く。
# 値は Konnect 上の AI Gateway 87ffec73-4403-49c8-bc99-81dc47fce093 の実測値。
env:
  konnect_mode: "on"
  cluster_mtls: pki
  cluster_control_plane: "fa722e22fb.us.cp.konghq.com:443"
  cluster_server_name: "fa722e22fb.us.cp.konghq.com"
  cluster_telemetry_endpoint: "fa722e22fb.us.tp.konghq.com:443"
  cluster_telemetry_server_name: "fa722e22fb.us.tp.konghq.com"
  cluster_cert: /etc/secrets/kong-cluster-cert/tls.crt
  cluster_cert_key: /etc/secrets/kong-cluster-cert/tls.key

image:
  repository: kong/kong-ai-gateway
  tag: "2.0.2"

proxy:
  type: LoadBalancer
  annotations:
    cloud.google.com/l4-rbs: "enabled"
    networking.gke.io/load-balancer-ip-addresses: shukawam-gke-aigw
```

**チャート既定の `image.repository` は `kong/kong-ai-gateway-dev` である。**
Konnect のセットアップ手順が指定していた `kong/kong-ai-gateway:2.0.2` に合わせる。

- [ ] **Step 4: レンダリングで確認する**

```bash
helm template kong-ai-gateway kong/kong-ai-gateway --version 0.1.0 -n kong \
  -f platform/kong-ai-gateway/values.yaml > /tmp/ai.yaml

grep -o "kong/kong-ai-gateway[a-z-]*:[0-9a-z.-]*" /tmp/ai.yaml | sort -u
# 期待: kong/kong-ai-gateway:2.0.2

python3 -c "
import yaml
for d in yaml.safe_load_all(open('/tmp/ai.yaml')):
    if isinstance(d,dict) and d.get('kind')=='Service' and 'proxy' in d['metadata']['name']:
        print(d['metadata']['name'], d['spec'].get('type'),
              (d['metadata'].get('annotations') or {}).get('networking.gke.io/load-balancer-ip-addresses'))
"
# 期待: kong-ai-gateway-kong-ai-gateway-proxy LoadBalancer shukawam-gke-aigw
```

期待値と違ったら報告して止まること。

- [ ] **Step 5: `apps/kong-ai-gateway.yaml` を multi-source に書き換える**

チャートと、`externalsecret.yaml` を含む git の path の両方を source に持つ。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong-ai-gateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://charts.konghq.com
      chart: kong-ai-gateway
      targetRevision: 0.1.0
      helm:
        valueFiles:
          - $values/platform/kong-ai-gateway/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      path: platform/kong-ai-gateway-extras
  destination:
    server: https://kubernetes.default.svc
    namespace: kong
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

**`externalsecret.yaml` は `platform/kong-ai-gateway-extras/` へ移動する。**
同じディレクトリを values 用と path 用の両方に使うと、Argo CD が values.yaml を
Kubernetes マニフェストとして適用しようとして失敗する。

- [ ] **Step 6: オペレータ専用 CR の 3 ファイルを削除する**

```bash
git rm platform/kong-ai-gateway/konnect-api-auth.yaml \
       platform/kong-ai-gateway/konnect-aigateway.yaml \
       platform/kong-ai-gateway/aigateway-dataplane.yaml
mkdir -p platform/kong-ai-gateway-extras
git mv platform/kong-ai-gateway/externalsecret.yaml platform/kong-ai-gateway-extras/
```

- [ ] **Step 7: 検証してコミット**

Run: `./scripts/validate.sh; echo $?`
Expected: `0`

```bash
git add -A platform/kong-ai-gateway platform/kong-ai-gateway-extras apps/kong-ai-gateway.yaml
git commit -m "feat: AI Gateway を kong/kong-ai-gateway チャートへ移行

Konnect の hybrid 接続をオペレータ CR ではなく values で直接指定する方式に変える。
DP のクライアント証明書は Konnect への登録が必要で、オペレータが自動化していた部分。"
```

---

## Task 4: Gateway API リソースの接続先を KIC に差し替える

**Files:**
- Modify: `platform/kong-gateway/gatewayclass.yaml`
- Delete: `platform/kong-gateway/gatewayconfiguration.yaml`
- Unchanged: `platform/kong-gateway/{certificate,gateway,httproute-redirect,httproute-argocd}.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: KIC（Task 2）、Gateway API CRD（Task 1）、`ClusterIssuer letsencrypt-prod`
- Produces: `https://argocd.gke.shukawam.me` への到達性

- [ ] **Step 1: `gatewayclass.yaml` を書き換える**

`controllerName` は KIC の既定値。`--gateway-api-controller-name` で変更していない限りこの値。
`parametersRef` が指していた `GatewayConfiguration` はオペレータ専用 CRD なので削除する。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  # KIC の既定の controllerName。オペレータの
  # konghq.com/gateway-operator から差し替えた。
  # 誤った値を書いても GatewayClass は作成でき、Gateway が黙って
  # Accepted=False になるだけなので、実機で status を確認すること。
  controllerName: konghq.com/kic-gateway-controller
  # parametersRef は書かない。GatewayConfiguration は
  # Kong Operator 専用 CRD であり、オペレータ削除に伴い存在しなくなる。
```

- [ ] **Step 2: `gatewayconfiguration.yaml` を削除する**

```bash
git rm platform/kong-gateway/gatewayconfiguration.yaml
```

- [ ] **Step 3: 他の 4 ファイルが無変更であることを確認する**

```bash
git status --porcelain platform/kong-gateway/
```
Expected: `gatewayclass.yaml` の変更と `gatewayconfiguration.yaml` の削除のみ。
`certificate.yaml` / `gateway.yaml` / `httproute-*.yaml` に変更が出ていたら意図しない編集。

- [ ] **Step 4: 検証してコミット**

Run: `./scripts/validate.sh; echo $?`
Expected: `0`

```bash
git add -A platform/kong-gateway
git commit -m "fix: GatewayClass の接続先を Kong Operator から KIC へ差し替え

controllerName を konghq.com/kic-gateway-controller に変更し、
オペレータ専用 CRD だった GatewayConfiguration への parametersRef を削除する。
Gateway / HTTPRoute / Certificate は無変更で流用できる。"
```

---

## Task 5: Kong Operator を削除する

**このタスクを最後に行う理由**: CR より先にオペレータを消すと、finalizer が処理されず
`AIGatewayDataPlane` などの CR が削除できなくなる。Task 3 で CR をリポジトリから消してあるので、
Argo CD が prune した後にオペレータを消す。

**Files:**
- Delete: `apps/kong-operator.yaml`
- Delete: `platform/kong-operator/values.yaml`
- Modify: `scripts/validate.sh`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: Task 1〜4 がすべて完了していること
- Produces: オペレータとその CRD が存在しない状態

- [ ] **Step 1: 旧 CR が削除済みであることを確認する**

**この確認が通るまで先へ進まないこと。**

```bash
kubectl get konnectapiauthconfiguration,konnectaigateway,aigatewaydataplane -n kong 2>&1
```
Expected: `No resources found` または `the server doesn't have a resource type`

残っている場合は finalizer で止まっている。オペレータが動いているうちに解消する必要がある。
状況を報告すること。

- [ ] **Step 2: `apps/kong-operator.yaml` と `platform/kong-operator/` を削除する**

```bash
git rm apps/kong-operator.yaml
git rm -r platform/kong-operator
```

- [ ] **Step 3: `scripts/validate.sh` の `render_targets` から kong-operator の行を削除する**

`platform/kong-operator/values.yaml|kong/kong-operator|1.4.0-rc.1|kong` の行を消す。
Task 2 で追加した `kong/ingress` の行は残す。
`kong/kong-ai-gateway` の行も追加する。

```
  "platform/kong-ai-gateway/values.yaml|kong/kong-ai-gateway|0.1.0|kong"
```

- [ ] **Step 4: `scripts/validate.sh` の GSA / 静的 IP の定数チェックの対象パスを確認する**

`platform/kong-gateway/gatewayconfiguration.yaml` を静的 IP の検証対象にしていた場合、
そのファイルは削除済みなので参照先を `platform/kong-ingress/values.yaml` に変える。
削除したファイルを参照したままだとスキップされ、検証が空振りする。

- [ ] **Step 5: 検証してコミット**

Run: `./scripts/validate.sh; echo $?`
Expected: `0`、かつ静的 IP の定数チェックが 2 件とも OK になること

```bash
git add -A apps platform scripts
git commit -m "feat: Kong Operator を削除する

Kong Gateway は kong/ingress、AI Gateway は kong/kong-ai-gateway へ移行済み。
CR を先に削除してからオペレータを消す順序を守っている。"
```

---

## Task 6: 実機で移行を完了させる

> **このタスクはクラスタを変更する。** 各ステップの前に状態を確認し、
> 想定と違えば止まって報告すること。

**Files:**
- Modify: `docs/known-issues.md`（解消した項目の更新）
- Modify: `docs/superpowers/specs/2026-08-24-argocd-platform-design.md`（Kong 関連 24 箇所）

- [ ] **Step 1: push して Argo CD に同期させる**

```bash
git push origin main
kubectl get applications -n argocd -w
```

- [ ] **Step 2: 順序どおりに収束するか観察する**

wave 0（CRD）→ wave 1（KIC / GatewayClass）→ wave 2（Gateway / HTTPRoute / AI Gateway）。

```bash
kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

- [ ] **Step 3: KIC のバージョンを確認する（最重要）**

```bash
kubectl get deploy -n kong -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
```
Expected: `kong/kubernetes-ingress-controller:3.5.13` が含まれること。
`3.5` や他のタグなら values が効いていない。

- [ ] **Step 4: 移行前に全停止していた症状が解消したか確認する**

```bash
kubectl logs -n kong deploy/kong-ingress-controller --since=3m | grep -c "failed posting new config"
```
Expected: `0`

Deployment 名が違う場合は `kubectl get deploy -n kong` で確認する。

- [ ] **Step 5: Gateway と HTTPRoute が Programmed になるか**

```bash
kubectl get gateway kong -n kong \
  -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
kubectl get httproute -A
```
Expected: `http=True` / `https=True`。移行前は `https` が Programmed にならなかった。

- [ ] **Step 6: 実際の到達性を確認する**

```bash
curl -sI https://argocd.gke.shukawam.me | head -1
curl -sI http://argocd.gke.shukawam.me | head -1
```
Expected: HTTPS が 200 系、HTTP が 301。**移行前はどちらも 404 だった。**

- [ ] **Step 7: 静的 IP を確認する**

```bash
kubectl get svc -n kong --field-selector spec.type=LoadBalancer
```
Expected: `35.221.95.244`（Gateway）と `34.84.176.193`（AI Gateway）。

- [ ] **Step 8: AI Gateway が Konnect に接続しているか確認する**

```bash
kubectl get pods -n kong | grep ai-gateway
```
Expected: `1/1 Running`。`0/1` なら Konnect への 401 の可能性がある。

Konnect 側のノード一覧に在籍しているかは、`docs/known-issues.md` に記録した
API 呼び出し（`GET /v1/ai-gateways/{id}/nodes`）で確認する。

- [ ] **Step 9: オペレータの残骸を確認する**

```bash
kubectl get crd | grep -E "konnect\.konghq|aigateway\.konghq|gateway-operator\.konghq"
kubectl get deploy,pods -n kong | grep -i operator
```

`kong-operator` Application は `prune: false` だったため CRD が残る可能性が高い。
残っていた場合、**手動削除するかどうかをコントローラに報告して裁定を仰ぐこと。**
CRD を消すとその型の CR がすべて消えるため、独断で消さない。

- [ ] **Step 10: `konghq.com/secret` ラベルが KIC でも必要か確認する**

`platform/kong-gateway/certificate.yaml` の `secretTemplate.labels` は、
Kong Operator が Secret の informer キャッシュを `konghq.com/secret=true` で
絞り込んでいたために必要だった。**KIC に同じ絞り込みがあるかは未確認である。**

Step 5 で `https` listener が `Programmed=True` になっていれば、KIC は
このラベルの有無に関わらず Secret を読めている（あるいはラベルが効いている）。
どちらかを切り分けるには、ラベルを外して KIC を再起動し、listener が
`Programmed` のままかを見る。

```bash
# 切り分け（任意。本番の可用性を損なうので、確認したい場合のみ）
kubectl patch certificate gke-shukawam-me -n kong --type json \
  -p '[{"op":"remove","path":"/spec/secretTemplate"}]'
kubectl label secret gke-shukawam-me-tls -n kong konghq.com/secret-
kubectl rollout restart deploy/kong-ingress-controller -n kong
# listener が Programmed のままなら KIC には不要
```

**結果に関わらず、コントローラに報告して裁定を仰ぐこと。**
不要と分かってもラベルを残す判断はあり得る（害が無く、将来オペレータに戻す余地を残す）。
独断で `certificate.yaml` を書き換えないこと。

- [ ] **Step 11: `docs/known-issues.md` を更新する**

「1. Gateway API の TLS listener を有効にすると全ルーティングが停止する」の項を、
**解消済み**として書き換える。以下を含めること。

- KIC 3.5.13 へのピン留めで解消したこと
- 解消の手段が「Kong Operator をやめて Helm に移行し、KIC のバージョンを自分で選べるようにしたこと」であること
- 「Kong Operator は状態記録が実体と食い違っても再計算しない」という項目は、
  オペレータを使わなくなったため参考情報として残すか削除するかを判断すること

- [ ] **Step 12: 旧 spec を更新する**

`docs/superpowers/specs/2026-08-24-argocd-platform-design.md` の Kong 関連 24 箇所を、
`2026-08-27-kong-helm-migration-design.md` で上書きされた旨がわかる形に更新する。
§6.8（Kong Operator）と §6.9（Kong Gateway）が主な対象。

**移行が実機で成功してから更新すること。** 先に書き換えると、途中で頓挫した場合に
どちらの文書も現実と合わなくなる。

- [ ] **Step 13: コミットして push**

```bash
git add docs/
git commit -m "docs: Kong Helm 移行の完了を反映

known-issues.md の TLS listener の項を解消済みに更新し、
旧 spec の Kong 関連記述を移行後の構成に合わせる。"
git push origin main
```

---

## 想定される失敗と対処

各タスクの実行中に想定外が起きたときの参照表。**表にない症状が出たら、
推測で対処せず状況を報告すること。**

| 事象 | 原因 | 対処 |
| --- | --- | --- |
| `Gateway` が `Accepted=False` | `GatewayClass.controllerName` の誤り、または KIC 未起動 | `kubectl get gatewayclass kong -o yaml` の status を見る。KIC の Pod が Running か確認 |
| Gateway API リソースが全滅（`no matches for kind`） | CRD が KIC より後の wave にある、または未導入 | Task 1 の Application が wave 0 で Synced か確認 |
| ルーティングが全停止（`value must be null`） | KIC が 3.5.5 未満 | Task 6 Step 3 でイメージタグを確認。`3.5` の浮動タグを引いていないか |
| `helm template` で values が反映されない | キーのパスが違う（サブチャートのエイリアス配下が必要） | Task 2 Step 2 / Task 3 Step 4 のレンダリング確認に戻る |
| LB の IP が静的 IP にならない | annotation の載せ先が違う | `<release>-gateway-proxy` / `<release>-kong-ai-gateway-proxy` に付いているか確認 |
| AI Gateway が Konnect に 401 | DP のクライアント証明書が Konnect に未登録 | `docs/known-issues.md` の手順で Konnect のノード一覧と証明書一覧を確認 |
| 旧 CR が削除できない | オペレータを先に消して finalizer が処理されない | Task 5 Step 1 の確認を飛ばしていないか。オペレータを一時的に戻す必要がある |
| Argo CD が source を拒否する | AppProject の `sourceRepos` に未登録 | Task 1 Step 3 で GitHub の gateway-api を追加したか確認 |
| `validate.sh` が空振りする | 削除したファイルを参照したまま | Task 5 Step 4 の参照先の更新を確認 |

## 移行前の状態（比較用）

移行が成功したと言えるのは、下記が変わったときである。

| 項目 | 移行前 | 移行後の期待 |
| --- | --- | --- |
| `https://argocd.gke.shukawam.me` | **404** | 200 系 |
| `http://argocd.gke.shukawam.me` | **404** | 301 |
| Gateway の `https` listener | `Programmed=False` | `Programmed=True` |
| 設定投入エラー | 3 秒ごとに継続 | 0 件 |
| `kong-gateway` Application | `OutOfSync` / `Degraded` | `Synced` / `Healthy` |
