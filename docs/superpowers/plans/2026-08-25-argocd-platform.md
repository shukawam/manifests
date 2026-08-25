# GKE プラットフォーム基盤 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GKE 上に Argo CD の App of Apps を構築し、cert-manager / External Secrets / OpenTelemetry / Kong Operator / Kong Gateway / Kong AI Gateway を GitOps で一括管理できる状態にする。

**Architecture:** `bootstrap/` に GitOps 化できない 2 段 (Terraform / Argo CD の helm install) を置き、それ以降は `apps/` の子 Application 群 (App of Apps) がすべてを同期する。Helm を使うコンポーネントは multi-source Application にして upstream チャート + git 上の `values.yaml` だけを管理する。sync wave で依存順を表現する。

**Tech Stack:** Argo CD 10.4.0 (v3.5.1) / cert-manager v1.21.1 / External Secrets 2.9.0 / OpenTelemetry Operator 0.122.0 / Kong Operator 1.4.0-rc.1 / Gateway API v1 / GKE Standard

**Spec:** `docs/superpowers/specs/2026-08-24-argocd-platform-design.md`

## Global Constraints

以下はすべてのタスクの要件に暗黙に含まれる。値は spec からの逐語コピー。

- リポジトリ: `https://github.com/shukawam/manifests.git` / ブランチ `main`
- Google Cloud プロジェクト: `gcp-fieldeng-dev` / リージョン: `asia-northeast1`
- リソース接頭辞: `shukawam` / クラスタ名: `shukawam-gke`
- 公開ドメイン: `gke.shukawam.me`（`argocd.gke.shukawam.me` / `aigw.gke.shukawam.me`）
- チャートバージョンは以下に固定する。勝手に上げない。
  - `argo/argo-cd` `10.4.0`
  - `jetstack/cert-manager` `v1.21.1`
  - `external-secrets/external-secrets` `2.9.0`
  - `open-telemetry/opentelemetry-operator` `0.122.0`
  - `kong/kong-operator` `1.4.0-rc.1`（`image.tag` は `2.3.0-rc.2`）
- API グループ: ESO は `external-secrets.io/v1`（`v1beta1` は使わない）/ `GatewayConfiguration` は `gateway-operator.konghq.com/v2beta1`（`v1beta1` は deprecated）/ Gateway API は `gateway.networking.k8s.io/v1`
- **`lookup` を使って自己署名証明書を生成する Helm オプションは一切使わない。** Argo CD では毎回再生成されて恒久 OutOfSync になる。該当する `opentelemetry-operator` と `kong-operator` は cert-manager 連携にする。
- 全 Application の `syncOptions` に `ServerSideApply=true` を必ず入れる。Kong Operator の CRD が client-side apply の annotation 上限を超えるため。
- 各タスクの最後は必ず `./scripts/validate.sh` が緑になってからコミットする。

---

## File Structure

| ファイル | 責務 |
| --- | --- |
| `README.md` | 全体像・実行順・フォーク手順・port-forward フォールバック |
| `docs/terraform-requirements.md` | Terraform 担当セッションへ渡す要件（API / GSA / 静的 IP / Cloud DNS） |
| `scripts/validate.sh` | 全マニフェストの検証。各タスクのテストはこれ |
| `projects/platform.yaml` | AppProject |
| `bootstrap/argocd/bootstrap.sh` | Argo CD の初回 helm install + root app apply |
| `bootstrap/argocd/root-app.yaml` | App of Apps のルート |
| `apps/*.yaml` | 子 Application 定義のみ（実体は置かない） |
| `platform/<component>/values.yaml` | Helm の values だけ |
| `platform/<component>/*.yaml` | チャートを持たないコンポーネントの実体 |

---

## Task 1: リポジトリ骨格と検証スクリプト

**Files:**
- Create: `.gitignore`
- Create: `scripts/validate.sh`
- Create: `README.md`
- Create: `docs/terraform-requirements.md`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `./scripts/validate.sh` — 引数なしで実行し、終了コード 0 なら全マニフェストが妥当。以降の全タスクがこれをテストとして使う。

- [ ] **Step 1: `.gitignore` を作る**

```
.DS_Store
*.tfstate
*.tfstate.*
.terraform/
*.tfvars
!*.tfvars.example
```

- [ ] **Step 2: 検証スクリプトを書く（実装より先に書く。これがテスト）**

`scripts/validate.sh`:

```bash
#!/usr/bin/env bash
# 全マニフェストの静的検証。CI もローカルもこれ 1 本。
set -euo pipefail

cd "$(dirname "$0")/.."

REPO_URL="https://github.com/shukawam/manifests.git"
fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf '\033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

# --- 1. Helm リポジトリを冪等に登録 -------------------------------------
helm repo add argo             https://argoproj.github.io/argo-helm                  >/dev/null 2>&1 || true
helm repo add jetstack         https://charts.jetstack.io                            >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io                    >/dev/null 2>&1 || true
helm repo add open-telemetry   https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add kong             https://charts.konghq.com                             >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# --- 2. values.yaml がチャートに対して正しくレンダリングされるか ---------
# "<values への相対パス>|<helm repo>/<chart>|<version>|<namespace>"
render_targets=(
  "platform/argo-cd/values.yaml|argo/argo-cd|10.4.0|argocd"
  "platform/cert-manager/values.yaml|jetstack/cert-manager|v1.21.1|cert-manager"
  "platform/external-secrets/values.yaml|external-secrets/external-secrets|2.9.0|external-secrets"
  "platform/opentelemetry-operator/values.yaml|open-telemetry/opentelemetry-operator|0.122.0|opentelemetry-operator-system"
  "platform/kong-operator/values.yaml|kong/kong-operator|1.4.0-rc.1|kong"
)
for t in "${render_targets[@]}"; do
  IFS='|' read -r vals chart ver ns <<<"$t"
  [ -f "$vals" ] || { note "skip (未作成): $vals"; continue; }
  if helm template release "$chart" --version "$ver" -n "$ns" -f "$vals" >/dev/null 2>/tmp/helm-err.txt; then
    ok "helm template $chart"
  else
    bad "helm template $chart"; sed 's/^/       /' /tmp/helm-err.txt | head -20
  fi
done

# --- 3. 素の YAML が構文的に妥当か -------------------------------------
for d in projects apps platform/cert-manager-issuers platform/secret-stores \
         platform/opentelemetry-collector platform/kong-gateway platform/kong-ai-gateway \
         bootstrap/argocd; do
  [ -d "$d" ] || continue
  shopt -s nullglob
  files=("$d"/*.yaml)
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || continue
  if kubectl apply --dry-run=client -f "$d" >/dev/null 2>/tmp/kubectl-err.txt; then
    ok "kubectl --dry-run=client $d"
  else
    # CRD 未導入のクラスタでは未知 kind が引っかかるため、YAML 構文だけは必ず見る
    if yq eval-all 'true' "$d"/*.yaml >/dev/null 2>&1; then
      note "warn (CRD 未導入と思われる。YAML 構文は妥当): $d"
    else
      bad "YAML 構文エラー: $d"; sed 's/^/       /' /tmp/kubectl-err.txt | head -10
    fi
  fi
done

# --- 4. repoURL が全ファイルで一致しているか ---------------------------
if [ -d apps ] || [ -d bootstrap ]; then
  bad_urls=$(grep -rhoE 'repoURL: https://github\.com/[^ ]+' apps bootstrap 2>/dev/null \
             | sort -u | grep -v "repoURL: ${REPO_URL}\$" || true)
  if [ -z "$bad_urls" ]; then ok "repoURL が ${REPO_URL} で統一されている"
  else bad "repoURL の不一致"; printf '%s\n' "$bad_urls" | sed 's/^/       /'; fi
fi

# --- 5. 全 Application に ServerSideApply=true があるか -----------------
if [ -d apps ]; then
  for f in apps/*.yaml; do
    [ -f "$f" ] || continue
    kind=$(yq eval '.kind' "$f")
    [ "$kind" = "Application" ] || continue
    if yq eval '.spec.syncPolicy.syncOptions[] | select(. == "ServerSideApply=true")' "$f" | grep -q .; then
      ok "ServerSideApply=true: $f"
    else
      bad "ServerSideApply=true が無い: $f"
    fi
  done
fi

# --- 6. bootstrap.sh（shellcheck があれば） ----------------------------
if [ -f bootstrap/argocd/bootstrap.sh ]; then
  bash -n bootstrap/argocd/bootstrap.sh && ok "bash -n bootstrap.sh" || bad "bootstrap.sh 構文エラー"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck bootstrap/argocd/bootstrap.sh scripts/validate.sh && ok "shellcheck" || bad "shellcheck"
  else
    note "shellcheck 未インストールのためスキップ (brew install shellcheck)"
  fi
fi

exit $fail
```

- [ ] **Step 3: 実行権限を付けて走らせ、まだ何も無い状態で通ることを確認**

Run:
```bash
chmod +x scripts/validate.sh && ./scripts/validate.sh
```
Expected: 終了コード 0。`skip (未作成)` が並ぶだけで FAIL は出ない。
（これが「最初は空で緑、以降マニフェストを足すたびに検証対象が増える」という設計）

- [ ] **Step 4: `docs/terraform-requirements.md` を書く**

spec §7 をそのまま独立文書にする。別セッションへこのファイルだけ渡せる形にすること。
以下を必ず含める。

- API: `secretmanager.googleapis.com`, `dns.googleapis.com` を `apis.tf` の `required_apis` に追加
- GSA `shukawam-external-secrets` + `roles/secretmanager.secretAccessor` + WI バインド `external-secrets/external-secrets`
- GSA `shukawam-cert-manager` + `roles/dns.admin` + WI バインド `cert-manager/cert-manager`
- `google_compute_address` を **regional (`asia-northeast1`)** で 2 つ: `shukawam-gke-gateway` / `shukawam-gke-aigw`
- `google_dns_managed_zone`（パブリック、`gke.shukawam.me.`）
- `google_dns_record_set`: `*.gke.shukawam.me.` A → gateway IP / `aigw.gke.shukawam.me.` A → aigw IP
- output: `external_secrets_ksa_annotation`, `cert_manager_ksa_annotation`, `dns_zone_name_servers`, 2 つの IP アドレス
- OTel Collector 用の GSA・ロールは**既存のままで追加不要**である旨

- [ ] **Step 5: `README.md` を書く**

以下の節を含める。

1. 何を作るリポジトリか（コンポーネント表）
2. 実行順（spec §5.1 の 7 ステップ）
3. `bootstrap/gke` → `bootstrap/argocd` の実行方法
4. フォークして使う場合の repoURL 一括置換ワンライナー
5. **`kubectl port-forward svc/argocd-server -n argocd 8080:80` を常時フォールバックとして明記**
6. **AI Gateway が平文 HTTP で公開されるため、Konnect 側で key-auth 等の認証を必ず有効にすること**（spec §6.10 のセキュリティ注意）

- [ ] **Step 6: git を初期化してコミット**

```bash
git init -b main
git add .gitignore scripts/ README.md docs/
git commit -m "chore: リポジトリ骨格と検証スクリプトを追加"
```

- [ ] **Step 7: GitHub の public リポジトリを作って push**

> **⚠ 実行前にユーザーへ確認すること。** 外部公開を伴う不可逆な操作。

```bash
gh repo create shukawam/manifests --public --source=. --remote=origin --push
gh repo view shukawam/manifests --json url,visibility
```
Expected: `"visibility": "PUBLIC"` と URL が返る。
Argo CD は git 越しにしか同期できないため、**ここが通らないと以降のタスクは実機検証できない。**

---

## Task 2: AppProject / bootstrap スクリプト / Argo CD 自己管理

**Files:**
- Create: `projects/platform.yaml`
- Create: `platform/argo-cd/values.yaml`
- Create: `bootstrap/argocd/root-app.yaml`
- Create: `bootstrap/argocd/bootstrap.sh`
- Create: `bootstrap/argocd/README.md`
- Create: `apps/projects.yaml`
- Create: `apps/argo-cd.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: `scripts/validate.sh`（Task 1）
- Produces:
  - AppProject 名 `platform` — 以降の全 Application が `spec.project: platform` で参照する
  - `platform/argo-cd/values.yaml` — bootstrap.sh と `apps/argo-cd.yaml` の**両方**が参照する単一の真実
  - 全 Application が共有する `syncPolicy` の形（下の Step 4 のブロックを以降のタスクでそのまま複製する）

- [ ] **Step 1: `projects/platform.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: プラットフォーム基盤コンポーネント
  sourceRepos:
    - https://github.com/shukawam/manifests.git
    - https://argoproj.github.io/argo-helm
    - https://charts.jetstack.io
    - https://charts.external-secrets.io
    - https://open-telemetry.github.io/opentelemetry-helm-charts
    - https://charts.konghq.com
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  # CRD / ClusterRole / ClusterSecretStore / ClusterIssuer / GatewayClass を作るため
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

- [ ] **Step 2: `platform/argo-cd/values.yaml` を書く**

```yaml
global:
  domain: argocd.gke.shukawam.me

configs:
  params:
    # TLS は Kong Gateway で終端する。Argo CD 自身は平文 HTTP を話す
    server.insecure: true
  cm:
    url: https://argocd.gke.shukawam.me
    # label 方式は app.kubernetes.io/instance を書き換えてチャートの selector と衝突する
    application.resourceTrackingMethod: annotation
    timeout.reconciliation: 180s

server:
  service:
    type: ClusterIP
  # 公開は Gateway API の HTTPRoute で行うため、チャートの Ingress は使わない
  ingress:
    enabled: false
  resources:
    requests:
      cpu: 50m
      memory: 128Mi

controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

applicationSet:
  enabled: true

dex:
  enabled: false

notifications:
  enabled: false
```

- [ ] **Step 3: 検証を走らせて values がチャートに通ることを確認**

Run: `./scripts/validate.sh`
Expected: `OK   helm template argo/argo-cd` が出る。他は skip のまま。

- [ ] **Step 4: `apps/argo-cd.yaml` を書く（以降のタスクの雛形になる）**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-cd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 10.4.0
      helm:
        valueFiles:
          - $values/platform/argo-cd/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
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

- [ ] **Step 5: `apps/projects.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: projects
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: projects
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false     # AppProject を消すと全 Application が孤児になる
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

- [ ] **Step 6: `bootstrap/argocd/root-app.yaml` を書く**

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

- [ ] **Step 7: `bootstrap/argocd/bootstrap.sh` を書く**

```bash
#!/usr/bin/env bash
# Argo CD を helm で導入し、App of Apps のルートを apply するだけのスクリプト。
# 宣言的にできることは一切ここでやらない。
set -euo pipefail

cd "$(dirname "$0")"

ARGOCD_CHART_VERSION="10.4.0"
NAMESPACE="argocd"
VALUES="../../platform/argo-cd/values.yaml"
DRY_RUN=0

usage() {
  cat <<'USAGE'
使い方: ./bootstrap.sh [--dry-run] [--help]

  Argo CD (argo/argo-cd 10.4.0) を helm で導入し、root Application を apply する。
  以降の変更は git 側で行うこと。helm upgrade は使わない。

  --dry-run   何をするかだけ表示して終了する
  --help      このヘルプ

  注意: repoURL の差し替えオプションは用意していない。
        apps/*.yaml も同じ repoURL をハードコードしているため、
        フォーク時はリポジトリ全体を一括置換すること (README 参照)。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

for cmd in helm kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd が見つかりません" >&2; exit 1; }
done
[ -f "$VALUES" ] || { echo "values が見つかりません: $VALUES" >&2; exit 1; }

CONTEXT="$(kubectl config current-context)"
cat <<EOF

  対象クラスタ : ${CONTEXT}
  namespace    : ${NAMESPACE}
  チャート     : argo/argo-cd ${ARGOCD_CHART_VERSION}
  values       : ${VALUES}

EOF

if [ "$DRY_RUN" = "1" ]; then echo "(--dry-run のためここで終了)"; exit 0; fi

read -r -p "このコンテキストに Argo CD を導入します。よろしいですか? [y/N] " ans
case "$ans" in [yY]*) ;; *) echo "中止しました"; exit 1 ;; esac

echo "==> Helm リポジトリを登録"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

echo "==> Argo CD を導入"
helm upgrade --install argocd argo/argo-cd \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --values "$VALUES" \
  --wait --timeout 10m

echo "==> AppProject を適用"
kubectl apply -f ../../projects/platform.yaml

echo "==> root Application を適用"
kubectl apply -f root-app.yaml

cat <<EOF

  完了しました。

  初期パスワード:
    kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret \\
      -o jsonpath='{.data.password}' | base64 -d; echo

  UI (公開前・障害時のフォールバック):
    kubectl port-forward svc/argocd-server -n ${NAMESPACE} 8080:80
    → http://localhost:8080

  同期状況:
    kubectl get applications -n ${NAMESPACE} -w

  公開後:
    argocd login argocd.gke.shukawam.me --grpc-web

EOF
```

- [ ] **Step 8: `bootstrap/argocd/README.md` を書く**

前提（Terraform 適用済み、`gcloud container clusters get-credentials` 済み、
Secret Manager にトークン登録済み）、実行方法、`--dry-run`、
**「現在の kubectl コンテキストが `shukawam-gke` を向いているか必ず確認すること」**を書く。
（開発端末には `shukawam-zdf-gke` など別クラスタのコンテキストが存在する。）

- [ ] **Step 9: 検証を走らせる**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。以下がすべて OK になる。
- `OK   helm template argo/argo-cd`
- `OK   kubectl --dry-run=client projects`（もしくは warn。CRD 未導入なら warn で可）
- `OK   repoURL が https://github.com/shukawam/manifests.git で統一されている`
- `OK   ServerSideApply=true: apps/argo-cd.yaml`
- `OK   ServerSideApply=true: apps/projects.yaml`
- `OK   bash -n bootstrap.sh`

- [ ] **Step 10: bootstrap.sh の `--dry-run` を実行**

Run: `chmod +x bootstrap/argocd/bootstrap.sh && ./bootstrap/argocd/bootstrap.sh --dry-run`
Expected: コンテキスト名・チャート・values のパスが表示され、`(--dry-run のためここで終了)` で終わる。
クラスタには一切触らない。

- [ ] **Step 11: コミット**

```bash
git add projects apps bootstrap platform/argo-cd
git commit -m "feat: AppProject / bootstrap スクリプト / Argo CD 自己管理を追加"
```

---

## Task 3: cert-manager と ClusterIssuer

**Files:**
- Create: `platform/cert-manager/values.yaml`
- Create: `platform/cert-manager-issuers/clusterissuer-letsencrypt-staging.yaml`
- Create: `platform/cert-manager-issuers/clusterissuer-letsencrypt-prod.yaml`
- Create: `apps/cert-manager.yaml`
- Create: `apps/cert-manager-issuers.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: AppProject `platform`、`syncPolicy` の形（Task 2）
- Produces:
  - namespace `cert-manager` と ServiceAccount `cert-manager`（Workload Identity 済み）
  - `ClusterIssuer` `letsencrypt-staging` / `letsencrypt-prod` — Task 8 の `Certificate` が `issuerRef` で参照する

- [ ] **Step 1: `platform/cert-manager/values.yaml` を書く**

```yaml
crds:
  enabled: true
  keep: true

# Cloud DNS を DNS-01 で操作するため Workload Identity を紐付ける
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: shukawam-cert-manager@gcp-fieldeng-dev.iam.gserviceaccount.com

resources:
  requests:
    cpu: 20m
    memory: 64Mi
```

- [ ] **Step 2: 検証を走らせ、values がチャートに通ることを確認**

Run: `./scripts/validate.sh`
Expected: `OK   helm template jetstack/cert-manager`

- [ ] **Step 3: `apps/cert-manager.yaml` を書く**

Task 2 Step 4 の `syncPolicy` ブロックをそのまま複製すること。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://charts.jetstack.io
      chart: cert-manager
      targetRevision: v1.21.1
      helm:
        valueFiles:
          - $values/platform/cert-manager/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
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

- [ ] **Step 4: `ClusterIssuer` を 2 つ書く**

`platform/cert-manager-issuers/clusterissuer-letsencrypt-staging.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: shuhei.kawamura@konghq.com
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - dns01:
          cloudDNS:
            project: gcp-fieldeng-dev
            # Workload Identity を使うため serviceAccountSecretRef は書かない
```

`platform/cert-manager-issuers/clusterissuer-letsencrypt-prod.yaml`:

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
```

- [ ] **Step 5: `apps/cert-manager-issuers.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager-issuers
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: platform/cert-manager-issuers
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
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

- [ ] **Step 6: 検証を走らせる**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。`ServerSideApply=true: apps/cert-manager.yaml` と
`apps/cert-manager-issuers.yaml` が OK になる。

- [ ] **Step 7: コミット**

```bash
git add platform/cert-manager platform/cert-manager-issuers apps/cert-manager.yaml apps/cert-manager-issuers.yaml
git commit -m "feat: cert-manager と Let's Encrypt の ClusterIssuer を追加"
```

---

## Task 4: External Secrets Operator と ClusterSecretStore

**Files:**
- Create: `platform/external-secrets/values.yaml`
- Create: `platform/secret-stores/clustersecretstore.yaml`
- Create: `apps/external-secrets.yaml`
- Create: `apps/secret-stores.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: AppProject `platform`、`syncPolicy` の形（Task 2）
- Produces: `ClusterSecretStore` 名 **`gcp-secret-manager`** — Task 9 の `ExternalSecret` が
  `secretStoreRef.name` で参照する。API グループは `external-secrets.io/v1`。

- [ ] **Step 1: `platform/external-secrets/values.yaml` を書く**

```yaml
# Secret Manager にアクセスするのはコントローラだけ。
# webhook / cert-controller の SA には annotation を付けない。
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: shukawam-external-secrets@gcp-fieldeng-dev.iam.gserviceaccount.com

resources:
  requests:
    cpu: 20m
    memory: 64Mi
```

- [ ] **Step 2: 検証を走らせ、values がチャートに通ることを確認**

Run: `./scripts/validate.sh`
Expected: `OK   helm template external-secrets/external-secrets`

- [ ] **Step 3: `platform/secret-stores/clustersecretstore.yaml` を書く**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: gcp-secret-manager
spec:
  provider:
    gcpsm:
      projectID: gcp-fieldeng-dev
      # auth を書かない。ESO コントローラの Pod が Workload Identity で得る
      # Application Default Credentials がそのまま使われる。
      # auth.workloadIdentity を書くと serviceaccounts/token の RBAC など前提が増える。
```

- [ ] **Step 4: `apps/external-secrets.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://charts.external-secrets.io
      chart: external-secrets
      targetRevision: 2.9.0
      helm:
        valueFiles:
          - $values/platform/external-secrets/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
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

- [ ] **Step 5: `apps/secret-stores.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: secret-stores
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: platform/secret-stores
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
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

- [ ] **Step 6: 検証を走らせる**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。

- [ ] **Step 7: コミット**

```bash
git add platform/external-secrets platform/secret-stores apps/external-secrets.yaml apps/secret-stores.yaml
git commit -m "feat: External Secrets Operator と GCP Secret Manager の ClusterSecretStore を追加"
```

---

## Task 5: OpenTelemetry Operator

**Files:**
- Create: `platform/opentelemetry-operator/values.yaml`
- Create: `apps/opentelemetry-operator.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: cert-manager（Task 3）— webhook 証明書の発行元
- Produces:
  - `OpenTelemetryCollector` CRD（`opentelemetry.io/v1beta1`）— Task 6 が使う
  - Collector の既定イメージが `otel/opentelemetry-collector-contrib` になる
    → Task 6 の CR で `image:` を書かなくてよい

- [ ] **Step 1: `platform/opentelemetry-operator/values.yaml` を書く**

```yaml
admissionWebhooks:
  # autoGenerateCert は使わない。Argo CD の helm template では lookup が効かず、
  # reconcile のたびに証明書が再生成されて恒久 OutOfSync になる。
  certManager:
    enabled: true

manager:
  # googlecloud / googlemanagedprometheus exporter は contrib にしか入っていない。
  # ここで既定イメージを差し替えておくと Collector CR 側で image を書かずに済む。
  collectorImage:
    repository: otel/opentelemetry-collector-contrib
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
```

- [ ] **Step 2: 検証を走らせ、values がチャートに通ることを確認**

Run: `./scripts/validate.sh`
Expected: `OK   helm template open-telemetry/opentelemetry-operator`

- [ ] **Step 3: `certManager.enabled: true` が実際に効いているか、レンダリング結果で確認**

Run:
```bash
helm template otel open-telemetry/opentelemetry-operator --version 0.122.0 \
  -n opentelemetry-operator-system -f platform/opentelemetry-operator/values.yaml \
  | grep -c "kind: Certificate"
```
Expected: `1` 以上（cert-manager の `Certificate` が生成されている）。
`0` なら values のキー名が違う。`helm show values` で確認し直すこと。

- [ ] **Step 4: `apps/opentelemetry-operator.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: opentelemetry-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: https://open-telemetry.github.io/opentelemetry-helm-charts
      chart: opentelemetry-operator
      targetRevision: 0.122.0
      helm:
        valueFiles:
          - $values/platform/opentelemetry-operator/values.yaml
    - repoURL: https://github.com/shukawam/manifests.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: opentelemetry-operator-system
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

- [ ] **Step 5: 検証を走らせてコミット**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。

```bash
git add platform/opentelemetry-operator apps/opentelemetry-operator.yaml
git commit -m "feat: OpenTelemetry Operator を追加 (cert-manager 連携)"
```

---

## Task 6: OpenTelemetry Collector (DaemonSet + Deployment)

**Files:**
- Create: `platform/opentelemetry-collector/serviceaccount.yaml`
- Create: `platform/opentelemetry-collector/rbac.yaml`
- Create: `platform/opentelemetry-collector/collector-gateway.yaml`
- Create: `platform/opentelemetry-collector/collector-node.yaml`
- Create: `apps/opentelemetry-collector.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: `OpenTelemetryCollector` CRD（Task 5）、Terraform が作った GSA `shukawam-otel-collector`
- Produces:
  - namespace `opentelemetry` / ServiceAccount `otel-collector`
  - Service `otel-gateway-collector.opentelemetry.svc.cluster.local:4317`（OTLP gRPC）
    — アプリケーションのトレース送信先としても使う

- [ ] **Step 1: `serviceaccount.yaml` を書く**

namespace と ServiceAccount を 1 ファイルにまとめる。sync wave で SA を先に作る。

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: opentelemetry
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: opentelemetry
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    # Terraform の otel_collector_ksa_annotation 出力と一致させること
    iam.gke.io/gcp-service-account: shukawam-otel-collector@gcp-fieldeng-dev.iam.gserviceaccount.com
```

- [ ] **Step 2: `rbac.yaml` を書く**

Operator は CR ごとに SA を作れるが RBAC は作らない。`serviceAccount:` を明示する構成では自前で必要。

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources:
      - pods
      - namespaces
      - nodes
      - nodes/stats
      - nodes/proxy
      - services
      - endpoints
      - events
      - replicationcontrollers
      - resourcequotas
      - persistentvolumes
      - persistentvolumeclaims
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["daemonsets", "deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: opentelemetry
```

- [ ] **Step 3: `collector-gateway.yaml` を書く（node より先に立てる）**

node collector の送信先になるため sync wave を先にする。

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-gateway
  namespace: opentelemetry
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  mode: deployment
  # k8s_cluster receiver は重複計上を避けるため必ず 1 レプリカ
  replicas: 1
  serviceAccount: otel-collector
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1Gi
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      k8s_cluster:
        collection_interval: 30s
        allocatable_types_to_report: [cpu, memory]
    processors:
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 20
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      resourcedetection:
        detectors: [env, gcp]
        timeout: 10s
        override: false
      batch:
        send_batch_size: 1000
        timeout: 10s
    exporters:
      # メトリクスは GMP へ。googlecloud だと custom.googleapis.com の
      # メトリクス記述子上限とコストに当たる。
      googlemanagedprometheus:
        project: gcp-fieldeng-dev
      googlecloud:
        project: gcp-fieldeng-dev
        log:
          default_log_name: opentelemetry-collector
    service:
      pipelines:
        metrics:
          receivers: [otlp, k8s_cluster]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [googlemanagedprometheus]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [googlecloud]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [googlecloud]
```

- [ ] **Step 4: `collector-node.yaml` を書く**

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-node
  namespace: opentelemetry
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  mode: daemonset
  serviceAccount: otel-collector
  # /var/log/pods の読み取りに必要。GKE Standard だからできる (Autopilot では不可)
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  env:
    - name: K8S_NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
  volumes:
    - name: varlog
      hostPath:
        path: /var/log
  volumeMounts:
    - name: varlog
      mountPath: /var/log
      readOnly: true
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
  config:
    receivers:
      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: "${env:K8S_NODE_NAME}:10250"
        insecure_skip_verify: true
        metric_groups: [node, pod, container, volume]
      hostmetrics:
        collection_interval: 30s
        # disk / filesystem は root_path と /hostfs マウントが必要になり
        # コンテナ視点の値になってしまうため入れない。ノードの容量系は
        # kubeletstats 側で取れる。
        scrapers:
          cpu: {}
          load: {}
          memory: {}
          network: {}
      filelog:
        include: ["/var/log/pods/*/*/*.log"]
        # Collector 自身のログを読んでループするのを防ぐ
        exclude: ["/var/log/pods/opentelemetry_otel-node-collector*/*/*.log"]
        start_at: end
        include_file_path: true
        include_file_name: false
        retry_on_failure:
          enabled: true
        operators:
          # containerd / CRI-O / docker のどれでも解釈できる
          - id: container-parser
            type: container
    processors:
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 20
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.node.name
            - k8s.container.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
          - sources:
              - from: connection
      resourcedetection:
        detectors: [env, gcp]
        timeout: 10s
        override: false
      batch:
        send_batch_size: 1000
        timeout: 10s
    exporters:
      otlp:
        endpoint: otel-gateway-collector.opentelemetry.svc.cluster.local:4317
        tls:
          insecure: true
    service:
      pipelines:
        metrics:
          receivers: [kubeletstats, hostmetrics]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        logs:
          receivers: [filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
```

- [ ] **Step 5: `apps/opentelemetry-collector.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: opentelemetry-collector
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: platform/opentelemetry-collector
  destination:
    server: https://kubernetes.default.svc
    namespace: opentelemetry
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

- [ ] **Step 6: Collector の config が OTel Collector として妥当か、実物のバイナリで検証する**

`kubectl --dry-run` は CR の外形しか見ない。config の中身は contrib のバイナリに読ませて確かめる。

```bash
for f in collector-gateway collector-node; do
  yq eval '.spec.config' platform/opentelemetry-collector/$f.yaml \
    > /tmp/otel-$f.yaml
  docker run --rm -v /tmp/otel-$f.yaml:/etc/otel/config.yaml \
    otel/opentelemetry-collector-contrib:latest \
    validate --config=/etc/otel/config.yaml && echo "OK $f" || echo "FAIL $f"
done
```
Expected: 両方 `OK`。
`${env:K8S_NODE_NAME}` が未定義で怒られる場合は `K8S_NODE_NAME=dummy` を `-e` で渡す。
docker が使えない環境ではこの手順を飛ばし、Task 11 の実機同期で確認する。

- [ ] **Step 7: 検証を走らせてコミット**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。`platform/opentelemetry-collector` は CRD 未導入なら `warn` で可。

```bash
git add platform/opentelemetry-collector apps/opentelemetry-collector.yaml
git commit -m "feat: OpenTelemetry Collector (DaemonSet + Gateway) を追加"
```

---

## Task 7: Kong Operator

**Files:**
- Create: `platform/kong-operator/values.yaml`
- Create: `apps/kong-operator.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: cert-manager（Task 3）— CA と webhook 証明書の発行元
- Produces: Gateway API CRD 一式 + `gatewayconfigurations` / `konnect.*` / `aigateway.*` CRD
  — Task 8 と Task 9 が使う

- [ ] **Step 1: `platform/kong-operator/values.yaml` を書く**

```yaml
# Konnect が出力したセットアップコマンドの --set をそのまま values に落としたもの
image:
  tag: "2.3.0-rc.2"

env:
  ENABLE_CONTROLLER_KONNECT: true
  ENABLE_CONTROLLER_AIGATEWAYDATAPLANE: true

# 既定 (false) だと templates/kong-operator-ca.yaml が
#   {{ if not (lookup "v1" "Secret" ...) }}{{ $ca := genCA ... }}
# を通り、Argo CD の helm template では lookup が常に nil を返すため
# reconcile のたびに新しい CA が生成されて恒久 OutOfSync になる。
# チャートの values コメント自身も production では cert-manager を推奨している。
webhooks:
  options:
    certManager:
      enabled: true

certificateAuthority:
  options:
    certManager:
      enabled: true

resources:
  requests:
    cpu: 100m
    memory: 256Mi
```

- [ ] **Step 2: 検証を走らせ、values がチャートに通ることを確認**

Run: `./scripts/validate.sh`
Expected: `OK   helm template kong/kong-operator`

- [ ] **Step 3: `lookup` を通る CA テンプレートが消えたことを確認する（この Task の肝）**

同じ values で 2 回レンダリングし、差分が出ないことを見る。差分が出るなら
まだ `genCA` が走っており、Argo CD 上で恒久 OutOfSync になる。

```bash
helm template ko kong/kong-operator --version 1.4.0-rc.1 -n kong \
  -f platform/kong-operator/values.yaml > /tmp/ko-1.yaml
helm template ko kong/kong-operator --version 1.4.0-rc.1 -n kong \
  -f platform/kong-operator/values.yaml > /tmp/ko-2.yaml
diff /tmp/ko-1.yaml /tmp/ko-2.yaml && echo "OK: レンダリングが冪等" || echo "FAIL: まだ自己署名生成が走っている"
```
Expected: `OK: レンダリングが冪等`

- [ ] **Step 4: 必要な CRD が含まれることを確認**

```bash
helm template ko kong/kong-operator --version 1.4.0-rc.1 -n kong \
  -f platform/kong-operator/values.yaml --include-crds \
  | grep -E "^  name: (gatewayclasses\.gateway\.networking\.k8s\.io|httproutes\.gateway\.networking\.k8s\.io|gatewayconfigurations\.gateway-operator\.konghq\.com|aigatewaydataplanes\.aigateway\.konghq\.com|konnectaigateways\.konnect\.konghq\.com|konnectapiauthconfigurations\.konnect\.konghq\.com)$" | sort
```
Expected: 上記 6 つがすべて出力される。1 つでも欠けたら Task 8 / 9 が動かない。

- [ ] **Step 5: `apps/kong-operator.yaml` を書く**

**このアプリだけ `prune: false`。** `ko-crds.keep: true` は Helm の resource-policy であり
Argo CD には効かないため、CRD の誤削除を防ぐ。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
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
  destination:
    server: https://kubernetes.default.svc
    namespace: kong
  syncPolicy:
    automated:
      # CRD を誤って消さないため、このアプリだけ prune しない
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

- [ ] **Step 6: 検証を走らせてコミット**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。

```bash
git add platform/kong-operator apps/kong-operator.yaml
git commit -m "feat: Kong Operator を追加 (cert-manager 連携で CA の再生成を防止)"
```

---

## Task 8: Kong Gateway (Gateway API) と Argo CD の公開

**Files:**
- Create: `platform/kong-gateway/gatewayclass.yaml`
- Create: `platform/kong-gateway/gatewayconfiguration.yaml`
- Create: `platform/kong-gateway/certificate.yaml`
- Create: `platform/kong-gateway/gateway.yaml`
- Create: `platform/kong-gateway/httproute-redirect.yaml`
- Create: `platform/kong-gateway/httproute-argocd.yaml`
- Create: `apps/kong-gateway.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: Kong Operator の CRD（Task 7）、`ClusterIssuer letsencrypt-prod`（Task 3）、
  Terraform が作った静的 IP `shukawam-gke-gateway`
- Produces: `https://argocd.gke.shukawam.me` で Argo CD にアクセスできる状態

- [ ] **Step 1: `gatewayclass.yaml` を書く**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  controllerName: konghq.com/gateway-operator
  parametersRef:
    group: gateway-operator.konghq.com
    kind: GatewayConfiguration
    name: kong
    namespace: kong
```

- [ ] **Step 2: `gatewayconfiguration.yaml` を書く**

apiVersion は `v2beta1`（`v1beta1` は `deprecated: true` / `storage: false`）。

```yaml
apiVersion: gateway-operator.konghq.com/v2beta1
kind: GatewayConfiguration
metadata:
  name: kong
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  controlPlaneOptions:
    deployment:
      podTemplateSpec:
        spec:
          containers:
            - name: controller
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
  dataPlaneOptions:
    deployment:
      replicas: 2
      podTemplateSpec:
        spec:
          containers:
            - name: proxy
              resources:
                requests:
                  cpu: 200m
                  memory: 512Mi
    network:
      services:
        ingress:
          type: LoadBalancer
          # この CRD は spec.loadBalancerIP を公開していないため、
          # 静的 IP の固定は annotation 経由しか手段がない。
          # 効かない場合の対処は docs/terraform-requirements.md のフォールバック参照。
          annotations:
            cloud.google.com/l4-rbs: "enabled"
            networking.gke.io/load-balancer-ip-addresses: shukawam-gke-gateway
```

- [ ] **Step 3: `certificate.yaml` を書く**

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gke-shukawam-me
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "1"
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

- [ ] **Step 4: `gateway.yaml` を書く**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kong
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  gatewayClassName: kong
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.gke.shukawam.me"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: gke-shukawam-me-tls
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 5: `httproute-redirect.yaml` を書く**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  parentRefs:
    - name: kong
      namespace: kong
      sectionName: http
  hostnames:
    - "*.gke.shukawam.me"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

- [ ] **Step 6: `httproute-argocd.yaml` を書く**

`argo-cd` の Application ではなくここに置く。`argo-cd` は wave -1 で、
その時点では Gateway API の CRD がまだ存在しないため。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
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

- [ ] **Step 7: `apps/kong-gateway.yaml` を書く**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong-gateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: platform/kong-gateway
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

- [ ] **Step 8: 検証を走らせてコミット**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。

```bash
git add platform/kong-gateway apps/kong-gateway.yaml
git commit -m "feat: Kong Gateway (Gateway API) と Argo CD の HTTPS 公開を追加"
```

---

## Task 9: Kong AI Gateway

**Files:**
- Create: `platform/kong-ai-gateway/externalsecret.yaml`
- Create: `platform/kong-ai-gateway/konnect-api-auth.yaml`
- Create: `platform/kong-ai-gateway/konnect-aigateway.yaml`
- Create: `platform/kong-ai-gateway/aigateway-dataplane.yaml`
- Create: `apps/kong-ai-gateway.yaml`
- Test: `./scripts/validate.sh`

**Interfaces:**
- Consumes: `ClusterSecretStore gcp-secret-manager`（Task 4）、Kong Operator の CRD（Task 7）、
  Terraform が作った静的 IP `shukawam-gke-aigw`、Secret Manager の `konnect-api-token`
- Produces: `http://aigw.gke.shukawam.me:8000` で AI Gateway に到達できる状態

- [ ] **Step 1: `externalsecret.yaml` を書く**

`target.template.metadata.labels` が最重要。ESO は `template` を書かないと
ラベルを引き継がず、Kong Operator が Secret を認識できない。

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: konnect-api-auth
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "0"
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

- [ ] **Step 2: `konnect-api-auth.yaml` を書く**

```yaml
kind: KonnectAPIAuthConfiguration
apiVersion: konnect.konghq.com/v1alpha1
metadata:
  name: konnect-api-auth
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  type: secretRef
  secretRef:
    name: konnect-api-auth-secret
  serverURL: us.api.konghq.com
```

- [ ] **Step 3: `konnect-aigateway.yaml` を書く**

```yaml
kind: KonnectAIGateway
apiVersion: konnect.konghq.com/v1alpha1
metadata:
  name: kong
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  source: Mirror
  mirror:
    konnect:
      id: 87ffec73-4403-49c8-bc99-81dc47fce093
  konnect:
    authRef:
      name: konnect-api-auth
```

- [ ] **Step 4: `aigateway-dataplane.yaml` を書く**

Konnect が出力したものに、静的 IP の annotation だけを足した形。

```yaml
apiVersion: aigateway.konghq.com/v1alpha1
kind: AIGatewayDataPlane
metadata:
  name: kong
  namespace: kong
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  controlPlaneRef:
    type: konnectNamespacedRef
    konnectNamespacedRef:
      name: kong
  deployment:
    replicas: 1
    podTemplateSpec:
      spec:
        containers:
          - name: aigw
            image: kong/kong-ai-gateway:2.0.2
  network:
    services:
      ingress:
        type: LoadBalancer
        # この CRD も spec.loadBalancerIP を公開していないため annotation で固定する
        annotations:
          cloud.google.com/l4-rbs: "enabled"
          networking.gke.io/load-balancer-ip-addresses: shukawam-gke-aigw
        ports:
          - name: http
            port: 8000
            targetPort: 8000
```

- [ ] **Step 5: `apps/kong-ai-gateway.yaml` を書く**

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
  source:
    repoURL: https://github.com/shukawam/manifests.git
    targetRevision: main
    path: platform/kong-ai-gateway
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

- [ ] **Step 6: 検証を走らせてコミット**

Run: `./scripts/validate.sh`
Expected: 終了コード 0。

```bash
git add platform/kong-ai-gateway apps/kong-ai-gateway.yaml
git commit -m "feat: Kong AI Gateway (Konnect Mirror) を追加"
git push origin main
```

---

## Task 10: 静的 IP annotation の実機検証（最優先リスク）

> **前提: `bootstrap/gke` の Terraform が適用済みで、`shukawam-gke` クラスタと
> 2 つの静的 IP が存在すること。** 未了ならここで止まる。

**Files:**
- Modify: `platform/kong-gateway/gatewayconfiguration.yaml`（検証結果次第）
- Modify: `platform/kong-ai-gateway/aigateway-dataplane.yaml`（検証結果次第）
- Modify: `docs/terraform-requirements.md`（フォールバックを採る場合）

**Interfaces:**
- Consumes: Terraform の静的 IP `shukawam-gke-gateway` / `shukawam-gke-aigw`
- Produces: LB の EXTERNAL-IP が Terraform の静的 IP と一致している状態、
  もしくは代替手段が決まった状態

- [ ] **Step 1: kubectl コンテキストが対象クラスタを向いているか確認**

Run: `kubectl config current-context`
Expected: `gke_gcp-fieldeng-dev_asia-northeast1_shukawam-gke`
（開発端末には `shukawam-zdf-gke` など別クラスタのコンテキストがある。取り違えに注意）

- [ ] **Step 2: Terraform が作った静的 IP を控える**

```bash
gcloud compute addresses list --project gcp-fieldeng-dev --regions asia-northeast1 \
  --filter="name~'shukawam-gke-(gateway|aigw)'" --format="table(name,address,status)"
```
Expected: 2 行返り、いずれも `RESERVED`。

- [ ] **Step 3: 最小構成で annotation が効くか単体検証する**

Kong Operator を待たずに、素の Service で先に確かめる。ここで効かないなら
Operator 経由でも効かない。

```bash
kubectl create namespace ip-test --dry-run=client -o yaml | kubectl apply -f -
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ip-test
  namespace: ip-test
  annotations:
    cloud.google.com/l4-rbs: "enabled"
    networking.gke.io/load-balancer-ip-addresses: shukawam-gke-gateway
spec:
  type: LoadBalancer
  selector:
    app: nonexistent
  ports:
    - port: 80
      targetPort: 80
EOF
kubectl get svc -n ip-test ip-test -w
```
Expected: `EXTERNAL-IP` が Step 2 の `shukawam-gke-gateway` の IP と一致する（最大 5 分）。

- [ ] **Step 4: 結果に応じて分岐する**

**一致した場合** — 何も変えない。後片付けだけして次へ。

```bash
kubectl delete namespace ip-test
```

**一致しない / Pending のままの場合** — `kubectl describe svc -n ip-test ip-test` の
Events を読み、以下の順に試す。

1. `cloud.google.com/l4-rbs: "enabled"` を外して `networking.gke.io/load-balancer-ip-addresses` だけにする
2. annotation を両方外し、代わりに `spec.loadBalancerIP: <IP アドレス>` を直接書く
   → 効くなら **CRD が `loadBalancerIP` を公開していないため Operator 経由では使えない**。
      フォールバック（下の 3 か 4）へ進む
3. **フォールバック A**: 静的 IP の固定を諦め、Terraform の `google_dns_record_set` を
   削除して、`kubectl get svc` で得た IP を手で Cloud DNS に登録する運用にする。
   `docs/terraform-requirements.md` を書き換えること
4. **フォールバック B**: external-dns を platform アプリとして追加し、
   `Gateway` / `Service` から A レコードを自動同期させる。
   cert-manager と同じ `roles/dns.admin` を持つ GSA を再利用できる

- [ ] **Step 5: 採った結論を spec に追記してコミット**

`docs/superpowers/specs/2026-08-24-argocd-platform-design.md` の §9 リスク表の
該当行を、実際に起きたことと採った手段で置き換える。

```bash
git add -A
git commit -m "docs: 静的 IP annotation の実機検証結果を反映"
git push origin main
```

---

## Task 11: ブートストラップと全体の受け入れ確認

> **前提: Task 10 が完了し、`gke.shukawam.me` の NS 委任（`dnsv.jp` 側）が
> 済んでいること。** 委任前に走らせると証明書が取れず Task が止まる。

**Files:**
- Modify: `README.md`（実機で判明した手順の追記）

**Interfaces:**
- Consumes: これまでの全タスク
- Produces: 全 Application が Synced / Healthy で、`https://argocd.gke.shukawam.me` が開ける状態

- [ ] **Step 1: NS 委任が完了しているか確認**

Run: `dig +short NS gke.shukawam.me @1.1.1.1`
Expected: `ns-cloud-XX.googledomains.com.` が 4 本返る。
返らない場合は `dnsv.jp` 側の NS レコード登録が未了。ここで止めること。

- [ ] **Step 2: Secret Manager にトークンがあるか確認**

```bash
gcloud secrets versions access latest --secret konnect-api-token \
  --project gcp-fieldeng-dev | head -c 8; echo "..."
```
Expected: トークンの先頭が表示される。無ければ spec §8.2 の手順で登録する。

- [ ] **Step 3: ブートストラップを実行**

```bash
./bootstrap/argocd/bootstrap.sh
```
Expected: helm install が完了し、`AppProject` と root Application が apply される。
コンテキスト確認のプロンプトで `shukawam-gke` であることを必ず目視する。

- [ ] **Step 4: 全 Application が Synced / Healthy になるまで待つ**

```bash
kubectl get applications -n argocd -w
```
Expected: 12 個（root + 子 11 個）がすべて `Synced` / `Healthy`。
止まったものがあれば `kubectl describe application -n argocd <name>` で理由を読む。
wave 順（-2 → -1 → 0 → 1 → 2）に落ち着いていくはず。

- [ ] **Step 5: 恒久 OutOfSync が起きていないことを確認（Task 5 / 7 の対策の答え合わせ）**

3 分ほど置いてから 2 回続けて見る。

```bash
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status
sleep 180
kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status
```
Expected: 2 回とも全部 `Synced`。
`kong-operator` か `opentelemetry-operator` が `OutOfSync` を繰り返すなら
cert-manager 連携の values が効いていない。`kubectl get app -n argocd <name> -o json |
jq '.status.resources[] | select(.status=="OutOfSync")'` で対象リソースを特定する。

- [ ] **Step 6: 証明書を確認**

```bash
kubectl get certificate,certificaterequest,order,challenge -n kong
```
Expected: `Certificate/gke-shukawam-me` が `READY=True`。
`Pending` なら `kubectl describe challenge -n kong` で DNS-01 の失敗理由を読む
（多くは NS 委任か `roles/dns.admin` の欠落）。

- [ ] **Step 7: LB の IP と DNS 解決を確認**

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
dig +short argocd.gke.shukawam.me @1.1.1.1
dig +short aigw.gke.shukawam.me @1.1.1.1
```
Expected: それぞれ Task 10 で確定した IP に解決される。

- [ ] **Step 8: Argo CD に HTTPS で入れることを確認**

```bash
curl -sI https://argocd.gke.shukawam.me | head -1
curl -sI http://argocd.gke.shukawam.me | head -1
argocd login argocd.gke.shukawam.me --grpc-web
```
Expected: HTTPS が `HTTP/2 200`、HTTP が `HTTP/1.1 301`、CLI ログインが成功。
CLI が失敗する場合は `--grpc-web` が付いているか確認する。

- [ ] **Step 9: ESO と Kong の状態を確認**

```bash
kubectl get externalsecret,secret -n kong
kubectl get -n kong konnectapiauthconfiguration,konnectaigateway,aigatewaydataplane -o wide
```
Expected: `konnect-api-auth-secret` が存在し、3 つの Kong CR がいずれも Ready/Programmed。

- [ ] **Step 10: テレメトリが Google Cloud に届いていることを確認**

```bash
kubectl get opentelemetrycollector -n opentelemetry
kubectl logs -n opentelemetry -l app.kubernetes.io/name=otel-gateway-collector --tail=50
gcloud logging read 'resource.type="k8s_container"' --project gcp-fieldeng-dev --limit 5 --freshness=10m
```
Expected: Collector のログに exporter のエラーが無く、Cloud Logging に直近のログが入っている。
Cloud Monitoring の Metrics Explorer で `prometheus_target` のリソースタイプが見えることも確認する。
エラーが出る場合は Workload Identity の annotation と Terraform 出力を突き合わせる。

- [ ] **Step 11: 実機で判明したことを README に反映してコミット**

想定と違った手順・待ち時間・注意点を `README.md` の該当箇所に追記する。

```bash
git add -A
git commit -m "docs: 実機ブートストラップで判明した手順を README に反映"
git push origin main
```
