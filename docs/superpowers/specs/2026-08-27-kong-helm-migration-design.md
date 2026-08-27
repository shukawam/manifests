# Kong Operator から Helm Chart への移行 設計

- 日付: 2026-08-27
- 対象: `apps/kong-operator.yaml` / `apps/kong-gateway.yaml` / `apps/kong-ai-gateway.yaml` と
  対応する `platform/` 配下
- 前提設計: `docs/superpowers/specs/2026-08-24-argocd-platform-design.md`（本書が上書きする範囲を明記）

## 1. なぜ変更するか

### 直接の理由

Kong Operator 2.3.0-rc.2 が Gateway の TLS 証明書を Kong の宣言的設定へ変換する際、
ネストした SNI に証明書への逆参照を設定し、Kong の DB-less スキーマがこれを拒否する
（`certificate` エンティティが `value must be null`）。宣言的設定は 1 トランザクションのため、
**この 1 エンティティで当該 Gateway のルーティングが全停止する**。
経緯と実機での切り分けは `docs/known-issues.md` に記録済み。

上流では [KIC issue #7831](https://github.com/Kong/kubernetes-ingress-controller/issues/7831)
として修正され、**KIC 3.5.5 の "Fixed an issue with SNI generation in dbless mode. (#7853)"**
で解消している。最新は 3.5.13（2026-08-07）。

**Kong Operator では KIC のバージョンを選べない。** オペレータは KIC を Go の依存として持たず
（commit `b8b646c` の `go.mod` に該当モジュールなし）変換コードを取り込んでおり、
上流の修正が入るのを待つしかない。`2.3.0-rc.3` の CHANGELOG にも該当記載はない。

**Helm Chart なら KIC のイメージタグを自分で固定できる。** これが移行の決め手である。

### 副次的な理由

今回の調査で、オペレータには「自分の状態記録を信じ、外部の実体と食い違っても再計算しない」
性質が 2 箇所で観測された。

- 設定投入が失敗している間、ソース側を変更しても同じ設定を再送し続ける（Pod 再起動が必要）
- `AIGatewayDataPlaneCertificate` の `status.id` が Konnect に存在しない ID を指したまま
  `Programmed=True` を報告し、再登録を試みない（CR 削除で解消）

いずれも「同期は成功しているのに動かない」型で、原因の特定に時間を要する。

## 2. 決定事項

| 論点 | 決定 |
| --- | --- |
| Kong Gateway | `kong/ingress` チャートで導入する |
| AI Gateway | `kong/kong-ai-gateway` チャートに移行して**維持**する |
| Argo CD の公開 | **Gateway API を継続**する（Ingress へは変えない） |
| Kong Operator | 関連 CRD ごと**削除**する |

## 3. チャートとバージョン

すべて 2026-08-27 時点で `helm search repo` / `helm template` により実在と挙動を確認済み。

| チャート | version | appVersion | 用途 |
| --- | --- | --- | --- |
| `kong/ingress` | `0.24.0` | 3.9 | KIC + Kong Gateway |
| `kong/kong-ai-gateway` | `0.1.0` | 2.0.2-rc.2 | Konnect 接続の AI Gateway DP |

`kong/ingress` は薄いラッパで、実体は `kong` サブチャート（依存宣言は `=3.2.0` 固定）を
`controller` / `gateway` の 2 エイリアスで 2 回インスタンス化する構成。

### 3.1 KIC のイメージタグを固定する

```yaml
controller:
  ingressController:
    image:
      tag: "3.5.13"
```

**チャート既定の `3.5` という浮動タグは使わない。** 3.5.13 相当を引く可能性は高いが、
本リポジトリの正しさを浮動タグに預けない。本移行の目的そのものが
「KIC のバージョンを自分で決めること」であり、`3.5.5` 未満を引いた瞬間に
移行前と同じ全停止に戻る。values にその理由をコメントで残す。

### 3.2 検証済みの values パス

実際に上書きしてレンダリング結果が変わることを確認した（値のパスを推測しない）。

| パス | レンダリング結果 |
| --- | --- |
| `controller.ingressController.image.tag` | `kong/kubernetes-ingress-controller:3.5.13` |
| `gateway.image.tag` | `kong:<指定値>` |
| `gateway.proxy.type` / `gateway.proxy.annotations` | Service `<release>-gateway-proxy` に反映 |

## 4. ファイル構成

```
apps/
  kong-ingress.yaml          # 新規（kong/ingress、multi-source）  wave 1
  kong-gateway.yaml          # 既存を流用（Gateway API リソース）  wave 2
  kong-ai-gateway.yaml       # 既存を流用（チャート + ExternalSecret）wave 2
  kong-operator.yaml         # 削除
platform/
  kong-ingress/values.yaml   # 新規
  kong-gateway/              # 既存。gatewayclass.yaml を書き換え、gatewayconfiguration.yaml を削除
    gatewayclass.yaml        #   controllerName を KIC のものに、parametersRef を削除
    certificate.yaml         #   無変更
    gateway.yaml             #   無変更
    httproute-redirect.yaml  #   無変更
    httproute-argocd.yaml    #   無変更
  kong-ai-gateway/
    values.yaml              # 新規（kong/kong-ai-gateway 用）
    externalsecret.yaml      # 維持
    konnect-api-auth.yaml    # 削除（オペレータ CRD）
    konnect-aigateway.yaml   # 削除（オペレータ CRD）
    aigateway-dataplane.yaml # 削除（オペレータ CRD）
  kong-operator/             # ディレクトリごと削除
```

`platform/kong-gateway/` の 4 ファイルが無変更で残るのが、Gateway API を継続する利点である。

## 5. Gateway API の接続先を差し替える

`GatewayClass` の `controllerName` を、オペレータのものから KIC のものへ変える。
`parametersRef` が指していた `GatewayConfiguration` はオペレータ専用 CRD なので削除する。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
spec:
  controllerName: konghq.com/kic-gateway-controller   # 実装時に実機で確認する
```

**`controllerName` の値は実装時に必ず実機で確認する。** 誤った値を書いても
`GatewayClass` は作成でき、`Gateway` が黙って `Accepted=False` になるだけである。
KIC の Deployment の args / env、または KIC が発行する `GatewayClass` の status から確定させる。

## 6. 静的 IP

Task 10 で `networking.gke.io/load-balancer-ip-addresses` が GKE で機能することは実証済み。
オペレータ生成の Service でも本番で有効だった。今回は載せる先が変わるだけである。

```yaml
gateway:
  proxy:
    type: LoadBalancer
    annotations:
      cloud.google.com/l4-rbs: "enabled"
      networking.gke.io/load-balancer-ip-addresses: shukawam-gke-gateway
```

AI Gateway 側は `kong/kong-ai-gateway` チャートの proxy Service に
`shukawam-gke-aigw` を同様に指定する（パスは実装時に確認する）。

## 7. Gateway API の CRD をどこで入れるか

Gateway API の CRD（`gatewayclasses` / `gateways` / `httproutes` 等）は
これまで Kong Operator チャートの `gwapi-standard-crds` サブチャートが提供していた。
オペレータ削除に伴い供給元が消えるため、代替が必要である。

`kong/ingress` が Gateway API CRD を同梱するかは**実装時に `helm template --include-crds` で確認する**。
同梱しない場合は、Gateway API 標準 CRD を適用する Application を 1 つ追加する
（`apps/gateway-api-crds.yaml`、wave 0）。

**CRD が無い状態で `platform/kong-gateway/` が同期されると全リソースが失敗する。**
sync wave で CRD 提供元が先に来ることを保証する。

## 8. `konghq.com/secret` ラベルの扱い

`platform/kong-gateway/certificate.yaml` の `secretTemplate.labels` は**残す**。

このラベルは Kong Operator が Secret の informer キャッシュを絞り込んでいたため必要だった。
KIC に同じ絞り込みがあるかは未確認である。付いていて困るものではないため、
外して壊すより残して実機で確認する。KIC で不要と確認できたら、その時点で削除を判断する。

## 9. 削除の順序

**CR を先に、オペレータを最後に消す。** 逆順にすると、`AIGatewayDataPlane` などの CR が
finalizer で残って削除できず、Konnect 側の登録も宙に浮く。

```
1. apps/kong-ai-gateway.yaml を Helm 版へ差し替え
   → Argo CD が旧 CR (KonnectAPIAuthConfiguration / KonnectAIGateway / AIGatewayDataPlane) を prune
   → finalizer が外れて削除されることを確認する
2. apps/kong-gateway.yaml から gatewayconfiguration.yaml を削除、gatewayclass.yaml を差し替え
3. apps/kong-ingress.yaml を追加して Kong Gateway を導入
4. apps/kong-operator.yaml を削除
   → オペレータの Deployment と CRD が prune される
5. 残存 CRD を確認し、必要なら手動で削除する
```

**手順 4 で `konnect.*` / `aigateway.*` / `gateway-operator.*` CRD が消える。**
**訂正 (2026-08-27, 最終レビューで判明): 当初「`kong-operator` Application は
`prune: false` にしてあるので Application 削除時に CRD は残る」と書いていたが、これは誤り。**
`syncPolicy.automated.prune` が防ぐのは自動 sync 時に Git から削除されたリソースが
誤って消されることだけであり、Application 自体を削除したときのカスケード削除
（finalizer 経由の子リソース削除）には一切効かない。カスケード削除を止めるのは
`argocd.argoproj.io/sync-options: Delete=false` や `helm.sh/resource-policy: keep`
であって、`prune` ではない。

Kong Operator が同梱する CRD には `helm.sh/resource-policy: keep` が付いており
（実測で確認済み。対照的に、移行後の `kong/ingress` が同梱する CRD にはこの
アノテーションが無い）、これが実際に CRD を守っていた要因である。したがって
`kong-operator` Application を削除すると、CRD 自体は `resource-policy: keep`
により残るが、**CRD に紐づく CR（`AIGatewayDataPlane` 等）はオペレータの
finalizer 処理に依存しているため、オペレータ Pod が既に消えた後では
finalizer が外れず CR が Terminating のまま残留するリスクがある。**

正しい対処:
1. **CR を先に削除する（本セクション冒頭の手順どおり、オペレータ稼働中に）。**
   オペレータが生きているうちに CR を消せば finalizer が正しく処理される。
2. CRD 自体を残すか消すか制御したい場合は、`prune: false` ではなく
   `argocd.argoproj.io/sync-options: Delete=false` を該当 CRD リソースに
   付けるか、`helm.sh/resource-policy: keep` の有無を明示的に確認する。
3. `prune: false` はあくまで自動 sync 時の誤削除防止としてのみ機能している
   ことを前提に読むこと（Application 削除時の安全網にはならない）。

**再訂正 (2026-08-27, 実機カットオーバー後):** 上記の
「Kong Operator が同梱する CRD には `helm.sh/resource-policy: keep` が付いている」
という記述は**同梱 CRD 全体には当てはまらない**。実測では、Kong Operator 由来の
`*.gateway.networking.k8s.io`（Gateway API 標準の 10 CRD）には
`helm.sh/resource-policy: keep` が**付いていなかった**。`keep` が付いていたのは
`gateway-operator.konghq.com` / `konnect.konghq.com` / `aigateway.konghq.com` 系だけである。

つまり `kong-operator` Application をそのまま削除していれば、**Gateway API の
10 CRD がカスケード削除され、`Gateway` / `HTTPRoute` / `GatewayClass` が
まとめて消えていた**。実際のカットオーバーでは、削除前に 10 CRD すべてへ
`argocd.argoproj.io/sync-options=Delete=false` を手で付与することでこれを回避した。

さらに実機では、CR 削除時に以下の追加対処が必要だった。

- `Gateway/kong` に 3 つの finalizer が付いており、オペレータ削除後は誰も外さない
  （デッドロック）。オペレータ稼働中に `Gateway` を先に消す必要がある。
- 取り残された `DataPlane` / `ControlPlane` と、それらが作った
  `dataplane-admin-*` / `dataplane-ingress-*` Service は finalizer を手で外して削除した。
- `KonnectAIGateway` / `KonnectAPIAuthConfiguration` は Argo CD の prune 対象になった後も
  finalizer（`gateway.konghq.com/konnect-cleanup`,
  `konnect.konghq.com/konnectapiauth-in-use`）が残り、Application が
  「waiting for deletion」で停止した。手で finalizer を外して解消した。
- ESO が作った Secret にも `gateway.konghq.com/secret-in-use-by-konnect-resource`
  が残り、`ExternalSecret` の foregroundDeletion を塞いでいた。

**教訓: オペレータを消す前に、そのオペレータが finalizer を付けている
リソースをすべて洗い出して先に消す。** 消し損ねると、finalizer を外せる主体が
いなくなり、以降はすべて手作業になる。

## 10. 想定される失敗

| 事象 | 原因 | 対処 |
| --- | --- | --- |
| `Gateway` が `Accepted=False` | `GatewayClass.controllerName` の誤り | §5 のとおり実機で確認した値を使う |
| ルーティングが全停止（`value must be null`） | KIC が 3.5.5 未満 | `controller.ingressController.image.tag` を確認 |
| `platform/kong-gateway/` が全滅 | Gateway API CRD の供給元が無い | §7 の CRD Application を追加する |
| AI Gateway が Konnect に 401 | 証明書の再登録が必要 | `docs/known-issues.md` の手順（CR 削除で作り直し）を参照 |
| 旧 CR が削除されない | finalizer 残存 | オペレータを消す前に CR を消す（§9） |
| LB の IP が静的 IP にならない | annotation の位置が違う | `<release>-gateway-proxy` Service に付いているか確認 |

## 11. 検証方法

```bash
# 1. KIC のバージョンが固定されているか（最重要）
kubectl get deploy -n kong -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[*].image}{"\n"}{end}'
#    → kong/kubernetes-ingress-controller:3.5.13 であること

# 2. 全 Application が Synced / Healthy
kubectl get applications -n argocd

# 3. Gateway と HTTPRoute が Programmed になるか（移行前はここで止まっていた）
kubectl get gateway kong -n kong -o jsonpath='{range .status.listeners[*]}{.name}={.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
kubectl get httproute -A

# 4. 設定投入エラーが出ていないこと（移行前は 3 秒ごとに出ていた）
kubectl logs -n kong deploy/<kic-deploy> --since=2m | grep -c "failed posting new config"
#    → 0 であること

# 5. 実際の到達性
curl -sI https://argocd.gke.shukawam.me | head -1     # 200 系
curl -sI http://argocd.gke.shukawam.me | head -1      # 301

# 6. 静的 IP
kubectl get svc -n kong --field-selector spec.type=LoadBalancer
#    → 35.221.95.244 / 34.84.176.193

# 7. AI Gateway が Konnect に接続しているか
#    Konnect API: GET /v1/ai-gateways/{id}/nodes に DP が在籍し last_ping が現在であること

# 8. オペレータの残骸が無いこと
kubectl get crd | grep -E "konnect\.konghq|aigateway\.konghq|gateway-operator\.konghq"
```

`./scripts/validate.sh` は `render_targets` の書き換えが必要になる
（`platform/kong-operator/values.yaml` → `platform/kong-ingress/values.yaml` ほか）。
