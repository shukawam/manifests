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
