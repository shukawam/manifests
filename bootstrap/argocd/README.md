# bootstrap/argocd

Argo CD を helm で導入し、App of Apps のルート Application (`root-app.yaml`) を
apply するだけのスクリプトです。以降の変更は宣言的に git 側（このリポジトリ）で
行い、`helm upgrade` は二度と手で叩きません。

## 前提

以下がすべて完了していること（詳細は `docs/superpowers/specs/2026-08-24-argocd-platform-design.md` §5.1）。

1. `bootstrap/gke` の Terraform が `apply` 済みで、`shukawam-gke` クラスタ・IAM・
   DNS ゾーン・静的 IP が作成済みであること（`bootstrap/gke` は別セッションが
   所有するため、このスクリプトからは一切触らない）。
2. `dnsv.jp` 側に `gke` サブドメインの NS 委任が完了していること
   （証明書取得 (DNS-01) の前提。未完了でも Argo CD 自体の導入は進められるが、
   `cert-manager-issuers` 以降が証明書 `Pending` のまま止まる）。
3. `gcloud container clusters get-credentials shukawam-gke \
     --region asia-northeast1 --project gcp-fieldeng-dev` を実行済みで、
   kubeconfig に `shukawam-gke` 用のコンテキストが追加されていること。
4. Secret Manager に `konnect-api-token` が登録済みであること。

## ⚠️ kubectl コンテキストの確認（最重要）

**このスクリプトはコンテキストを検証しません。** 表示された対象クラスタ名を
**自分の目で確認してから** `y` を押してください。

この開発端末には、Terraform が作成する対象クラスタ `shukawam-gke` とは**別の**
既存クラスタのコンテキスト `gke_gcp-fieldeng-dev_asia-northeast1_shukawam-zdf-gke`
（`shukawam-zdf-gke`）が既に登録されています。名前が非常に紛らわしく、
うっかり切り替えを忘れたまま実行すると **別クラスタに Argo CD を誤って導入**
してしまいます。

実行前に必ず:

```bash
kubectl config current-context
# → gke_gcp-fieldeng-dev_asia-northeast1_shukawam-gke になっているか確認
#   (shukawam-zdf-gke ではないこと！)

# 違っていれば切り替える
kubectl config use-context gke_gcp-fieldeng-dev_asia-northeast1_shukawam-gke
```

`bootstrap.sh` は実行時に現在のコンテキスト名を画面に表示し、`y/N` の確認を
求めます。ここで表示されるクラスタ名が `shukawam-gke` であることを必ず確認して
から `y` と答えてください。少しでも自信がなければ `--dry-run` で再確認するか、
`N` で中止してください。

## 実行方法

```bash
cd bootstrap/argocd
chmod +x bootstrap.sh

# 何をするか（対象クラスタ・チャートバージョン・values パス）だけ確認する。
# クラスタには一切触らない。
./bootstrap.sh --dry-run

# コンテキストを確認した上で本実行
./bootstrap.sh
```

`--dry-run` はコンテキスト名・namespace・チャート・values のパスを表示して
`(--dry-run のためここで終了)` と出力するだけで終了し、helm / kubectl による
変更は一切行いません。何度実行しても安全です。

## このスクリプトがやること

1. `helm` / `kubectl` の存在確認、現在の kube-context の表示
2. `helm repo add argo https://argoproj.github.io/argo-helm && helm repo update`
3. `helm upgrade --install argocd argo/argo-cd --version 10.4.0 \
     --values ../../platform/argo-cd/values.yaml --wait`
4. `kubectl apply -f ../../projects/platform.yaml`（AppProject `platform`）
5. `kubectl apply -f root-app.yaml`（App of Apps のルート）
6. 初期 admin パスワードの確認方法と port-forward コマンドを案内して終了

values は `platform/argo-cd/values.yaml` を相対パスでそのまま読みます。
`bootstrap/argocd/` 側に values を複製することはしません。導入直後から
`apps/argo-cd.yaml` が同じチャートバージョン・同じ values ファイルを参照する
ため、Argo CD は起動直後から自分自身を Synced と判定し、以後は git 経由の
自己管理に移行します（`helm` が残す `sh.helm.release.v1.argocd.*` Secret は
無害なのでそのまま残します）。

## repoURL について

`repoURL` の差し替えオプション（`--repo-url` 等）は**あえて用意していません**。
子 Application (`apps/*.yaml`) も同じ `https://github.com/shukawam/manifests.git`
をハードコードしており、ルートだけ差し替えても整合しないためです。

フォークして別リポジトリで使う場合は、リポジトリ全体を一括置換してください。

```bash
grep -rl 'github.com/shukawam/manifests' apps bootstrap projects platform \
  | xargs sed -i '' 's#github.com/shukawam/manifests#github.com/<you>/<repo>#g'
```

## 導入後の確認

```bash
# 初期パスワード
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 同期状況
kubectl get applications -n argocd -w

# UI（公開前・障害時のフォールバック）
kubectl port-forward svc/argocd-server -n argocd 8080:80
# → http://localhost:8080

# 公開後
argocd login argocd.gke.shukawam.me --grpc-web
```
