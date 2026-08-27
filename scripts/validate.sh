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
# --force-update: 同名エイリアスが既に別 URL で登録されていた場合、それを
# 黙って温存すると以後誤ったリポジトリから pull し続けてしまうため、
# 常に URL を上書きする。
helm repo add argo             https://argoproj.github.io/argo-helm                  --force-update >/dev/null 2>&1 || true
helm repo add jetstack         https://charts.jetstack.io                            --force-update >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io                    --force-update >/dev/null 2>&1 || true
helm repo add open-telemetry   https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null 2>&1 || true
helm repo add kong             https://charts.konghq.com                             --force-update >/dev/null 2>&1 || true
# ここで失敗しても `|| true` は付けない。付けると set -e に頼った暗黙の
# 中断ができなくなり、古い/不在のチャートに対して以降の検証を通してしまう
# （中断より悪い）。失敗した場合はメッセージを出してから明示的に終了する。
if ! helm repo update >/tmp/helm-repo-update-err.txt 2>&1; then
  bad "helm repo update に失敗しました"
  sed 's/^/       /' /tmp/helm-repo-update-err.txt
  exit 1
fi

# --- 2. values.yaml がチャートに対して正しくレンダリングされるか ---------
# "<values への相対パス>|<helm repo>/<chart>|<version>|<namespace>"
render_targets=(
  "platform/argo-cd/values.yaml|argo/argo-cd|10.4.0|argocd"
  "platform/cert-manager/values.yaml|jetstack/cert-manager|v1.21.1|cert-manager"
  "platform/external-secrets/values.yaml|external-secrets/external-secrets|2.9.0|external-secrets"
  "platform/opentelemetry-operator/values.yaml|open-telemetry/opentelemetry-operator|0.122.0|opentelemetry-operator-system"
  "platform/kong-ingress/values.yaml|kong/ingress|0.24.0|kong"
  "platform/kong-ai-gateway/values.yaml|kong/kong-ai-gateway|0.1.0|kong"
)
for t in "${render_targets[@]}"; do
  IFS='|' read -r vals chart ver ns <<<"$t"
  [ -f "$vals" ] || { note "skip (未作成): $vals"; continue; }

  # Argo CD が実際に使うリリース名は spec.sources[0].helm.releaseName
  # があればそれ、無ければ metadata.name (apps/*.yaml)。固定名 "release"
  # でレンダリングすると、例えば cert-manager のコントローラ SA が
  # "release-cert-manager" になり、Workload Identity のバインディングを
  # 壊す名前を検証してしまう。values.yaml のディレクトリ名 (例:
  # platform/cert-manager) は apps/*.yaml のファイル名 (apps/cert-manager.yaml)
  # と一致する規約なので、それで対応する apps ファイルを引く。
  apps_file="apps/$(basename "$(dirname "$vals")").yaml"
  release="release"
  if [ -f "$apps_file" ]; then
    derived="$(yq eval '.spec.sources[0].helm.releaseName // .metadata.name // ""' "$apps_file")"
    if [ -n "$derived" ] && [ "$derived" != "null" ]; then
      release="$derived"
    else
      note "warn: $apps_file からリリース名を取得できず release にフォールバック"
    fi
  else
    note "warn: $apps_file が無いため release name を release にフォールバック ($vals)"
  fi

  # --include-crds: Argo CD は既定でこれを渡す (helm.skipCrds の既定は
  # false)。付けないと crds/ ディレクトリに CRD を置くサブチャート
  # (例: kong-operator の gwapi-standard-crds) の CRD がまるごと
  # 検証対象外になる。
  if helm template "$release" "$chart" --version "$ver" -n "$ns" -f "$vals" --include-crds >/dev/null 2>/tmp/helm-err.txt; then
    ok "helm template $chart (release: $release)"
  else
    bad "helm template $chart"; sed 's/^/       /' /tmp/helm-err.txt | head -20
  fi
done

# --- 3. argo-cd のチャート版・リリース名が bootstrap.sh と一致しているか --
# チャート版 10.4.0 は bootstrap/argocd/bootstrap.sh・apps/argo-cd.yaml・
# この validate.sh (render_targets) の 3 箇所に、リリース名 argocd は
# 前 2 者に重複している。どちらかがずれると Argo CD がもう一組立ち上がり、
# HTTPRoute の backend が解決しなくなる（過去に実際に起きた重大欠陥）。
if [ -f apps/argo-cd.yaml ] && [ -f bootstrap/argocd/bootstrap.sh ]; then
  apps_argocd_version="$(yq eval '.spec.sources[0].targetRevision' apps/argo-cd.yaml)"
  apps_argocd_release="$(yq eval '.spec.sources[0].helm.releaseName' apps/argo-cd.yaml)"
  bootstrap_argocd_version="$(grep -oE '^ARGOCD_CHART_VERSION="[^"]*"' bootstrap/argocd/bootstrap.sh \
                                 | sed -E 's/^ARGOCD_CHART_VERSION="([^"]*)"$/\1/' || true)"
  bootstrap_argocd_release="$(grep -oE '^helm upgrade --install [^ ]+' bootstrap/argocd/bootstrap.sh \
                                 | awk '{print $4}' || true)"

  if [ -n "$bootstrap_argocd_version" ] && [ "$apps_argocd_version" = "$bootstrap_argocd_version" ]; then
    ok "argo-cd チャート版が一致: apps/argo-cd.yaml=${apps_argocd_version} bootstrap.sh=${bootstrap_argocd_version}"
  else
    bad "argo-cd チャート版の不一致: apps/argo-cd.yaml=${apps_argocd_version:-<なし>} bootstrap.sh=${bootstrap_argocd_version:-<なし>}"
  fi

  if [ -n "$bootstrap_argocd_release" ] && [ "$apps_argocd_release" = "$bootstrap_argocd_release" ]; then
    ok "argo-cd リリース名が一致: apps/argo-cd.yaml=${apps_argocd_release} bootstrap.sh=${bootstrap_argocd_release}"
  else
    bad "argo-cd リリース名の不一致: apps/argo-cd.yaml=${apps_argocd_release:-<なし>} bootstrap.sh=${bootstrap_argocd_release:-<なし>}"
  fi
else
  bad "argo-cd 版/リリース名検証に必要なファイルが無い (apps/argo-cd.yaml, bootstrap/argocd/bootstrap.sh)"
fi

# --- 4. 素の YAML が構文的に妥当か -------------------------------------
# クラスタへの到達性をループに入る前に 1 回だけ安価に確認する。
# 到達できない場合（kubeconfig の認証切れ等、マニフェストの正しさとは無関係な
# 理由）は kubectl --dry-run=client を一切実行せず、YAML 構文チェックのみに
# 縮退する。構文が壊れていればこの場合でも従来どおり fail にする。
timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin="gtimeout"
fi

cluster_reachable=0
reach_reason="unreachable"
if [ -z "$timeout_bin" ]; then
  # timeout/gtimeout がどちらも無いと、exec credential plugin がハングした場合に
  # プローブ自体を安全に打ち切れない。ハングするくらいなら、判定せずに
  # 到達不能とみなしてスキップする方が安全（フェイルセーフ）。
  reach_reason="no-timeout-bin"
elif "$timeout_bin" 5 kubectl cluster-info --request-timeout=3s >/dev/null 2>&1; then
  cluster_reachable=1
fi

if [ "$cluster_reachable" -eq 0 ]; then
  if [ "$reach_reason" = "no-timeout-bin" ]; then
    printf '\033[33mWARN\033[0m timeout/gtimeout が見つからないためクラスタ到達性を安全に判定できません。kubectl --dry-run=client によるスキーマ検証をスキップします\n'
    printf '     (解消: brew install coreutils で timeout/gtimeout を導入してください。YAML 構文チェックのみ継続します)\n'
  else
    printf '\033[33mWARN\033[0m クラスタに到達できないため、kubectl --dry-run=client によるスキーマ検証をスキップします\n'
    printf '     (原因: kubeconfig の認証切れ等が考えられます。復旧: gcloud auth login。YAML 構文チェックのみ継続します)\n'
  fi
fi

skipped_dirs=""
# platform/kong-ai-gateway はここに含めない。Task 4 で AIGatewayDataPlane
# (生の k8s マニフェスト) を Helm 化し、ディレクトリの中身が values.yaml
# (Helm values、kind/apiVersion を持たない) だけになったため。ここに入れると
# kubectl apply --dry-run=client が values.yaml を k8s マニフェストとして
# 検証しようとして "apiVersion not set, kind not set" で必ず fail する。
# values.yaml 自体の妥当性は上の「helm template」検証 (render_targets) で見る。
for d in projects apps platform/cert-manager-issuers platform/secret-stores \
         platform/opentelemetry-collector platform/kong-gateway \
         bootstrap/argocd; do
  [ -d "$d" ] || continue
  shopt -s nullglob
  files=("$d"/*.yaml)
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || continue

  if [ "$cluster_reachable" -eq 0 ]; then
    skipped_dirs="${skipped_dirs:+$skipped_dirs }$d"
    if yq eval-all 'true' "$d"/*.yaml >/dev/null 2>&1; then
      note "warn (クラスタ未到達のため kubectl --dry-run=client 未実行。YAML 構文は妥当): $d"
    else
      bad "YAML 構文エラー: $d"
    fi
    continue
  fi

  if kubectl apply --dry-run=client -f "$d" >/dev/null 2>/tmp/kubectl-err.txt; then
    ok "kubectl --dry-run=client $d"
  else
    # YAML 自体が構文的に壊れていれば、kubectl のエラー内容によらず fail
    if ! yq eval-all 'true' "$d"/*.yaml >/dev/null 2>&1; then
      bad "YAML 構文エラー: $d"; sed 's/^/       /' /tmp/kubectl-err.txt | head -10
    else
      # kubectl のエラーが「CRD 未導入」由来の行だけで構成されているかを見る。
      # それ以外のエラー（フィールド名の誤り・型違反・必須フィールド欠落など）が
      # 1 行でも混ざっていれば、CRD 未導入を理由に握りつぶさず fail にする。
      other_errors=$(grep -vE 'no matches for kind|ensure CRDs are installed|resource mapping not found for name' \
                       /tmp/kubectl-err.txt | sed '/^[[:space:]]*$/d' || true)
      if [ -n "$other_errors" ]; then
        bad "kubectl --dry-run=client $d"; sed 's/^/       /' /tmp/kubectl-err.txt | head -20
      else
        unknown_kinds=$(grep -oE 'no matches for kind "[^"]+"' /tmp/kubectl-err.txt \
                           | sed -E 's/no matches for kind "([^"]+)"/\1/' | sort -u | paste -sd, - || true)
        note "warn (CRD 未導入のため未検証な kind: ${unknown_kinds:-不明}. YAML 構文は妥当): $d"
      fi
    fi
  fi
done

if [ "$cluster_reachable" -eq 0 ] && [ -n "$skipped_dirs" ]; then
  printf '\033[33mWARN\033[0m kubectl --dry-run=client を未実行のディレクトリ:%s\n' "$skipped_dirs"
fi

# --- 5. repoURL が全ファイルで一致しているか ---------------------------
# github.com の repoURL は本来このリポジトリ自身を指しているべき、という前提の
# チェック（フォーク時の参照ずれ等、意図しない repoURL の混入を捕まえるのが目的）。
# ただし CRD 等を upstream から直接取り込む設計（例: Gateway API 標準 CRD）は
# 意図的に別の github.com リポジトリを参照するため、明示的な許可リストで例外化する。
# 許可リストにも本リポジトリにも一致しない github.com の repoURL は従来どおり FAIL。
ALLOWED_EXTERNAL_GITHUB_REPOS=(
  # Gateway API 標準 CRD を upstream から直接引く apps/gateway-api-crds.yaml 用。
  # kong/ingress は Gateway API CRD を同梱しないため、この Application が
  # KIC より前の wave で CRD を供給する。
  "https://github.com/kubernetes-sigs/gateway-api"
)

if [ -d apps ] || [ -d bootstrap ]; then
  found_urls=$(grep -rhoE 'repoURL: https://github\.com/[^ ]+' apps bootstrap 2>/dev/null | sort -u || true)
  bad_urls=""
  if [ -n "$found_urls" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      url="${line#repoURL: }"
      if [ "$url" = "$REPO_URL" ]; then
        continue
      fi
      allowed=0
      for a in "${ALLOWED_EXTERNAL_GITHUB_REPOS[@]}"; do
        if [ "$url" = "$a" ]; then
          allowed=1
          break
        fi
      done
      if [ "$allowed" -eq 0 ]; then
        bad_urls="${bad_urls:+$bad_urls$'\n'}$line"
      fi
    done <<<"$found_urls"
  fi
  if [ -z "$bad_urls" ]; then ok "repoURL が ${REPO_URL} または許可リストで統一されている"
  else bad "repoURL の不一致"; printf '%s\n' "$bad_urls" | sed 's/^/       /'; fi
fi

# --- 6. 全 Application に ServerSideApply=true があるか -----------------
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

# --- 7. bootstrap.sh（shellcheck があれば） ----------------------------
if [ -f bootstrap/argocd/bootstrap.sh ]; then
  bash -n bootstrap/argocd/bootstrap.sh && ok "bash -n bootstrap.sh" || bad "bootstrap.sh 構文エラー"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck bootstrap/argocd/bootstrap.sh scripts/validate.sh && ok "shellcheck" || bad "shellcheck"
  else
    note "shellcheck 未インストールのためスキップ (brew install shellcheck)"
  fi
fi

# --- 8. bootstrap/gke (Terraform) の静的検証と、マニフェスト側定数との整合 ------
# GSA の email やアドレス名は Terraform の命名規則 (format("%s-xxx", resource_prefix)) から
# 手打ちで書き写した文字列で、Terraform 側との自動的な結び付きが無い。ズレてもエラーには
# ならず、Workload Identity や LoadBalancer の静的 IP 紐付けが黙って壊れる
# （本プロジェクトで繰り返し起きている「沈黙する失敗」の典型形）ため、ここで突き合わせる。
if command -v terraform >/dev/null 2>&1; then
  if [ -d bootstrap/gke/.terraform ]; then
    if terraform -chdir=bootstrap/gke fmt -check >/tmp/tf-fmt-err.txt 2>&1; then
      ok "terraform fmt -check: bootstrap/gke"
    else
      bad "terraform fmt -check: bootstrap/gke (terraform -chdir=bootstrap/gke fmt で修正してください)"
      sed 's/^/       /' /tmp/tf-fmt-err.txt
    fi

    if terraform -chdir=bootstrap/gke validate >/tmp/tf-validate-err.txt 2>&1; then
      ok "terraform validate: bootstrap/gke"
    else
      bad "terraform validate: bootstrap/gke"
      sed 's/^/       /' /tmp/tf-validate-err.txt
    fi
  else
    note "skip (bootstrap/gke で terraform init 未実行のため fmt/validate は未実施)"
  fi
else
  note "skip (terraform コマンドが見つからないため bootstrap/gke の fmt/validate は未実施)"
fi

# variables.auto.tfvars は gitignore 対象の実値ファイルのため、他マシン (CI 含む) には
# 存在しない可能性がある。無ければ検証自体をスキップする。
if [ -f bootstrap/gke/variables.auto.tfvars ]; then
  resource_prefix="$(grep -E '^resource_prefix[[:space:]]*=' bootstrap/gke/variables.auto.tfvars \
                        | sed -E 's/^resource_prefix[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/' || true)"
  project_id="$(grep -E '^project_id[[:space:]]*=' bootstrap/gke/variables.auto.tfvars \
                   | sed -E 's/^project_id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/' || true)"

  if [ -n "$resource_prefix" ] && [ -n "$project_id" ]; then
    # "<マニフェストファイル>|<account_id / 静的IP名の接尾辞>|<種別: gsa または address>"
    tf_const_checks=(
      "platform/external-secrets/values.yaml|external-secrets|gsa"
      "platform/cert-manager/values.yaml|cert-manager|gsa"
      "platform/opentelemetry-collector/serviceaccount.yaml|otel-collector|gsa"
      "platform/kong-ingress/values.yaml|gke-gateway|address"
      "platform/kong-ai-gateway/values.yaml|gke-aigw|address"
    )
    for c in "${tf_const_checks[@]}"; do
      IFS='|' read -r file suffix kind <<<"$c"
      [ -f "$file" ] || { note "skip (未作成): $file"; continue; }

      if [ "$kind" = "gsa" ]; then
        expected="${resource_prefix}-${suffix}@${project_id}.iam.gserviceaccount.com"
        actual="$(grep -oE 'iam\.gke\.io/gcp-service-account:[[:space:]]*[^[:space:]]+' "$file" \
                     | head -1 | awk '{print $2}' || true)"
        label="GSA email"
      else
        expected="${resource_prefix}-${suffix}"
        actual="$(grep -oE 'networking\.gke\.io/load-balancer-ip-addresses:[[:space:]]*[^[:space:]]+' "$file" \
                     | head -1 | awk '{print $2}' || true)"
        label="静的 IP アドレス名"
      fi

      if [ -z "$actual" ]; then
        bad "$label が $file から抽出できませんでした"
      elif [ "$actual" = "$expected" ]; then
        ok "$label が Terraform の命名規則と一致: $file ($actual)"
      else
        bad "$label の不一致: $file の値=${actual} 期待値=${expected} (resource_prefix=${resource_prefix}, project_id=${project_id})"
      fi
    done
  else
    note "skip (bootstrap/gke/variables.auto.tfvars から resource_prefix / project_id を読めず、定数の整合検証は未実施)"
  fi
else
  note "skip (bootstrap/gke/variables.auto.tfvars が無い。gitignore 対象のため他マシンには存在しない)"
fi

exit $fail
