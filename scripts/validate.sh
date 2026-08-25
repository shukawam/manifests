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
for d in projects apps platform/cert-manager-issuers platform/secret-stores \
         platform/opentelemetry-collector platform/kong-gateway platform/kong-ai-gateway \
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
