# 既知の問題

## 1. Gateway API の TLS listener で全ルーティングが停止する（解決済み・2026-08-27）

**状態**: 解決済み。Kong Operator を廃止し、`kong/ingress` Helm Chart
（KIC 3.5.13 + Kong OSS 3.9.3）へ移行したことで解消した。
`https://argocd.gke.shukawam.me` は 200、`http://` は 301 で HTTPS へ誘導される。

### 症状（当時）

`Gateway` の HTTPS listener に cert-manager 発行の TLS Secret が紐付くと、
ControlPlane から DataPlane への宣言的設定の投入が HTTP 400 で全件失敗した。

```json
{
  "entity_type": "certificate",
  "errors": [{ "message": "value must be null", "type": "entity" }]
}
```

宣言的設定は 1 トランザクションのため、この 1 エンティティが拒否されると
その Gateway のルーティングが全部入らない。HTTP のリダイレクトルートも 404 になっていた。

### 原因（Kong のバージョン依存）

ネストした SNI に証明書への逆参照（`snis[].certificate.id`）が設定される点が争点で、
[KIC issue #7831](https://github.com/Kong/kubernetes-ingress-controller/issues/7831)
の系譜そのものだった。**どちらが正しいかは Kong 側のバージョンで反転する。**

| Kong | 逆参照あり | 逆参照なし |
| --- | --- | --- |
| Kong Enterprise 3.9.0.1+（当時使っていた `kong/kong-gateway:3.14` を含む） | 拒否 | 受理 |
| Kong OSS 3.9 / Kong Gateway 3.9.1.0+（現行の `kong:3.9.3`） | 受理 | 拒否 |

KIC 側も PR #7853 で逆参照を外し、回帰 [#7869] を受けて PR #7871 で
「常に逆参照を付ける」に戻している。現行の KIC 3.5.13 は後者。
したがって現構成（KIC 3.5.13 + Kong OSS 3.9.3）は整合しており、この問題は起きない。

### 教訓: Kong の設定エラーは「巻き添え」を含む

移行直後、別の原因で設定投入が失敗していた際にも
`certificate: value must be null` が併記された。`kong:3.9.3` に対して同じ形の
証明書エンティティを単体で POST すると **HTTP 201 で通る**（ローカル再現で確認）。

つまり Kong は、設定が他の理由で不正なときに限り、通常は許容している
ネストした外部キーについてもエラーを併記する。**flattened_errors に複数の
エンティティが並んだら、まず「単体でも落ちるのはどれか」を切り分けること。**
このときの真因は `redirect` プラグインの `config.location` だった（下記 3）。

---

## 2. TLS Secret には `konghq.com/secret: "true"` ラベルが必要（Kong Operator 固有・記録として保持）

Kong Operator は Secret の informer キャッシュを `konghq.com/secret=true` で絞り込んでいた。
このラベルが無い Secret はオペレータから**一切見えず**、`Gateway` の listener が
`InvalidCertificateRef`（`Secret ... not found`）のまま永久に止まる。
`kubectl get` では取得できるため発覚しにくい。

`platform/kong-gateway/certificate.yaml` の `spec.secretTemplate.labels` で付与している。
cert-manager が発行する Secret に手で付けても、cert-manager が `secretTemplate` から
再適用するため、Certificate 側で指定する必要がある。

**現在は Kong Operator を使っていない。** KIC が同じ絞り込みをするかは未検証だが、
ラベルが付いた状態でルーティングは正常に動作しているため、そのまま残している。

---

## 3. KIC は unmanaged アノテーションの無い GatewayClass を黙って無視する

**症状**: `GatewayClass` は `Accepted=True` になるのに、`Gateway` の status が
CRD 既定値のまま（`Accepted=Unknown` / `reason: Pending` /
`"Waiting for controller"` / `lastTransitionTime: 1970-01-01T00:00:00Z`）動かない。
**KIC のログにエラーも警告も一切出ない。**

**原因**: KIC の Gateway reconciler は unmanaged モードの GatewayClass しか扱わない。

```go
// internal/controllers/gateway/gateway_controller.go
if isGatewayClassUnmanaged(gwc.Annotations) {
    if result, err := r.reconcileUnmanagedGateway(ctx, log, gateway); err != nil { ... }
}
```

`konghq.com/gatewayclass-unmanaged` アノテーションが無いと、この if に入らず
status を一切書かずに return する。KIC 3.5.13 の `annotations.go` にも
「it's currently required that this annotation be present on all GatewayClass
resources: "unmanaged" mode is the only supported mode」と明記されている。

**対処**: `platform/kong-gateway/gatewayclass.yaml` で
`konghq.com/gatewayclass-unmanaged: "true"` を付与している。

**切り分けの勘所**: `lastTransitionTime` が `1970-01-01T00:00:00Z` なら、
それは CRD の既定値であって**どのコントローラも status を書いていない**証拠。
権限やコントローラの起動を疑う前にここを見る。KIC の
`CONTROLLER_LOG_LEVEL=debug` を一時的に有効にすると
`Processing gateway` → `Verifying gatewayclass` → `Checking deletion timestamp`
で止まっていることが確認できる。

---

## 4. RequestRedirect は hostname を省略できない（KIC + Kong 3.9+）

**症状**: 宣言的設定の投入が `config.location: "missing host in url"` で
HTTP 400 になり、その Gateway のルーティングが全停止する。

**原因**: KIC の `generateRequestRedirectUsingRedirectKongPlugin` は
`requestRedirect.hostname` が nil のとき **scheme を完全に無視して**
`location = path`（既定 `/`）を生成する。Kong 3.9+ の `redirect` プラグインは
`location` にホストを含む URL を要求するため、`scheme: https` だけを書いた
HTTP → HTTPS リダイレクトは必ず不正な設定になる。

## 5. traditional ルーターは `protocols` で HTTPS を除外しない

**症状**: HTTPS でアクセスしても、HTTP listener 側のリダイレクトルートにマッチして
無限リダイレクトになる（curl が 50 回で打ち切る）。

**原因**: `kong/ingress` チャートは `KONG_ROUTER_FLAVOR=traditional` で起動する。
traditional ルーターにおける `protocols` は「HTTPS 専用ルートに HTTP で来たときの
扱い」を決めるためのもので、`protocols: ["http"]` のルートから HTTPS リクエストを
除外しない。KIC は listener（`sectionName`）ごとに正しく `protocols` を出し分けるが、
**同一 host / path で http ルートと https ルートを併存させると衝突する。**

**対処（3 と 4 をまとめて解決する形）**: リダイレクト専用の HTTPRoute を作らない。
公開用の HTTPRoute を https listener だけに attach し、
`konghq.com/https-redirect-status-code: "301"` を付ける。Kong は https 専用ルートへ
HTTP で来たリクエストにこのコードを返すため、ルートは 1 本で済み衝突しない。
KIC は `kongstate.Route.overrideByAnnotation` で HTTPRoute のアノテーションを読むので、
Gateway API でもこのアノテーションが効く。

実装は `platform/kong-gateway/httproute-argocd.yaml`。

---

## 6. Gateway API のリソースが恒常的に OutOfSync になる

**症状**: 同期は成功するのに `Gateway` と `HTTPRoute` が OutOfSync のまま固定され、
selfHeal が延々と再 apply する。

**原因は 2 つある。**

1. KIC が `Gateway` に `konghq.com/publish-service` アノテーションを追記する
   （他マネージャ所有のフィールド）
2. Gateway API の CRD が既定値を埋める
   （`parentRefs.group/kind`, `backendRefs.group/kind/weight`, `rules.matches`,
   `certificateRefs.group`）

**対処**: 1 には Application に `ServerSideDiff=true` を付ける
（managedFields を見て他マネージャ所有フィールドを差分から除外する）。
2 は git 側に既定値を明示して書く。**両方必要で、片方だけでは収束しない。**

---

## 7. AI Gateway の DP 証明書を Konnect に登録する

**症状**: AI Gateway の Pod が Konnect へ接続できず 401 を繰り返す。

```
[rpc] unable to connect to peer: unexpected HTTP response code: 401
  uri: wss://<cp>.us.cp.konghq.com:443/v1/ai-gateway
```

**原因**: cert-manager が発行した DP クライアント証明書が Konnect 側に未登録。
Kong Operator を使っていた頃はオペレータが登録していたが、Helm 版では**登録は手動**。
証明書を更新（cert-manager の自動更新を含む）したら、その都度登録が必要になる。

**AI Gateway ID の調べ方**（Kong Operator の CR は削除済みなのでクラスタからは引けない）

```bash
TOKEN=$(gcloud secrets versions access latest --secret konnect-api-token --project gcp-fieldeng-dev)
curl -s -H "Authorization: Bearer $TOKEN" https://us.api.konghq.com/v1/ai-gateways \
  | jq -r '.data[] | "\(.id)\t\(.name)"'
```

**確認**（登録済み証明書の一覧。`{aigw-id}` は上で得た ID）

```bash
TOKEN=$(gcloud secrets versions access latest --secret konnect-api-token --project gcp-fieldeng-dev)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://us.api.konghq.com/v1/ai-gateways/{aigw-id}/data-plane-certificates" | jq '.data[].id'
```

実機の証明書と突き合わせる。

```bash
kubectl get secret kong-ai-gateway-kong-ai-gateway-cluster-cert -n kong \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -fingerprint -sha256
```

**登録**

```bash
kubectl get secret kong-ai-gateway-kong-ai-gateway-cluster-cert -n kong \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/dp.crt
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://us.api.konghq.com/v1/ai-gateways/{aigw-id}/data-plane-certificates" \
  -d "$(jq -Rs '{cert: .}' < /tmp/dp.crt)"
rm -f /tmp/dp.crt
```

**注意**: エンドポイントは `data-plane-certificates`。`certificates` も HTTP 200 を返すが
これは別のコレクション（常に 0 件）で、ここを見ても登録状況は分からない。

---

## 8. ESO が起動タイミングによって永久に認証できなくなる（解決済み・2026-08-27）

**症状**: `ClusterSecretStore/gcp-secret-manager` が
`Ready=False` / `InvalidProviderConfig` / `unable to create client` のまま復旧しない。
コントローラのログには `google: could not find default credentials`。
**Pod を再起動すると直る。**

**原因**: Workload Identity の設定は正しく、GSA の IAM バインディングも
`serviceAccount:gcp-fieldeng-dev.svc.id.goog[external-secrets/external-secrets]` で正しい。
同じ ServiceAccount のテスト Pod からは metadata server が GSA メールとトークンを返す。

問題は ESO プロセス内部にある。Go の `cloud.google.com/go/compute/metadata` は
`OnGCE()` の判定を `onGCEOnce.Do` で**プロセス寿命の間メモ化する**。

```go
func OnGCEWithContext(ctx context.Context) bool {
    onGCEOnce.Do(func() { onGCE = defaultClient.OnGCEWithContext(ctx) })
    return onGCE
}
```

GKE の `gke-metadata-server` は DaemonSet なので、ノード起動直後は ESO Pod と
競合する。ESO が先に（あるいはほぼ同時に）起動して探索に失敗すると
「GCE 上ではない」が固定され、以降 metadata server が正常化しても
**ESO は二度と ADC を取得できない**。実機では両 Pod の起動時刻が 3 秒差だった。

**対処**: `platform/external-secrets/values.yaml` で
`GCE_METADATA_HOST=169.254.169.254` を設定する。この環境変数があると
`OnGCEWithContext` は

```go
// The user explicitly said they're on GCE, so trust them.
if os.Getenv(metadataHostEnv) != "" { return true }
```

で探索せず即 true を返すため競合が消える。トークン取得は遅延評価かつ
リトライされるので、metadata server の準備完了を自然に待てる。
値はライブラリ既定と同じ documented metadata IP で、DNS 解決に依存しないよう
`metadata.google.internal` ではなく IP を使う。

**切り分けの勘所**: 「再起動すると直る」認証エラーを見たら、
設定ではなく**プロセス内キャッシュ**を疑う。Workload Identity が壊れているかは、
同じ ServiceAccount を指定したテスト Pod から metadata server を叩けば
コントローラと切り離して確認できる。

```bash
kubectl run wi-check -n external-secrets --rm -i --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"external-secrets"}}' \
  --image=curlimages/curl:8.11.1 -- \
  curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
```

---

## 9. AI Gateway を独立 LoadBalancer から Gateway API 経由に統合した（2026-08-28）

**変更前の方針**（README に明記されていた）: Kong AI Gateway は LLM のストリーミング
応答やタイムアウトに関する不確実性を避けるため、Gateway API (`kong-gateway`) とは
別の独立した LoadBalancer で `http://aigw.gke.shukawam.me:8000` を平文公開していた。

**変更後**: `platform/kong-gateway/httproute-aigw.yaml` で `kong-gateway` の
`https` listener に相乗りさせ、`https://aigw.gke.shukawam.me` として TLS 終端込みで
公開する。AI Gateway 側の Service は `ClusterIP` に変更し、直接公開はやめた。

**タイムアウト対策**: 元の懸念（ストリーミング中に Gateway API 側のタイムアウトで
接続が切れる）に対しては、HTTPRoute の `rules[].timeouts.request` /
`backendRequest` を両方 `0s` にして無効化した。Gateway API の仕様上
`0s` は「タイムアウトを無効化する」ことを意味する（GEP-2257）。

**残っているリスク**: この `0s` 設定は Kong (KIC) 側で実際にタイムアウトなしとして
機能することを実機で確認した記録がまだない。長時間ストリーミングする用途で問題が
出た場合、まずここを疑うこと。また `0s` は「無制限」なので、応答が返らないまま
接続が張られ続けるリソースリークの可能性もゼロではない。
