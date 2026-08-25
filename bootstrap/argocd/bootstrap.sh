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
