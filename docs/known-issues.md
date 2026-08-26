# 既知の問題

## 1. Gateway API の TLS listener を有効にすると全ルーティングが停止する

**状態**: 未解決（上流の修正待ち）
**影響**: `https://argocd.gke.shukawam.me` に到達できない。HTTP のリダイレクトも含め、
`Gateway` 配下のルーティングが**一切**機能しない。
**回避策**: 当面 `kubectl port-forward` で Argo CD にアクセスする（下記）。

### 症状

`Gateway` の HTTPS listener に cert-manager 発行の TLS Secret が紐付くと、
ControlPlane から DataPlane への宣言的設定の投入が HTTP 400 で全件失敗し、
3 秒間隔で無限にリトライする。

```json
{
  "entity_type": "certificate",
  "errors": [{ "message": "value must be null", "type": "entity" }]
}
```

```
[controlplane.dataplane-synchronizer] Could not update kong admin
  performing update for https://10.21.0.x:8444 failed: HTTP status 400
  (message: "failed posting new config to /config")
```

宣言的設定は 1 トランザクションのため、**この 1 エンティティが拒否されると
その Gateway のルーティングが全部入らない**。HTTP のリダイレクトルートも 404 になる。

### 原因

ネストした SNI に証明書への逆参照が設定されるが、Kong の DB-less スキーマは
ネストされた外部キーが null であることを要求する。

[KIC issue #7831](https://github.com/Kong/kubernetes-ingress-controller/issues/7831)
と症状が一致する。KIC 3.4.0 で混入、3.3.1 が最後の正常版、PR #7853 で修正済み。

ただし **Kong Operator 2.x は `kubernetes-ingress-controller` を Go の依存として持たず**
（commit `b8b646c` の `go.mod` に該当モジュールなし）、変換コードを自リポジトリに
取り込んでいる。KIC 側の修正が自動的に効くとは限らない。
`2.3.0-rc.3` の CHANGELOG にも該当の記載はない。

**このリポジトリのマニフェストの誤りではない。** 設定を変えても解決しない。

### 実機で確認した切り分け（2026-08-26）

単一変数で 3 回検証した。

| 操作 | 結果 |
| --- | --- |
| `Gateway` から HTTPS listener を削除 | エラー継続 |
| Secret から `konghq.com/secret` ラベルを削除 | エラー継続 |
| 上記に加えてオペレータ Pod を再起動 | **エラー停止** |

ここから 2 点が確定した。

1. 拒否されているのは cert-manager 発行の Let's Encrypt ワイルドカード証明書
   （`*.gke.shukawam.me`, RSA 2048）から変換された `certificate` エンティティ。
   失敗エンティティの UUID はこの Secret に由来する
2. **ControlPlane は設定投入が失敗している間、設定を再計算しない。**
   ソース側を変更しても同一の設定を再送し続け、Pod を再起動して初めて反映される。
   → **設定を修正しても、オペレータを再起動しない限り復旧しない**

### 環境

| | |
| --- | --- |
| Kong Operator | 2.3.0-rc.2 (chart 1.4.0-rc.1) commit `b8b646c83e86210e540fa8ebdd7a10d15627b8d7` |
| Kong Gateway (DataPlane) | `kong/kong-gateway:3.14`（Operator の既定） |
| モード | DB-less / hybrid、Gateway API v1 |
| 証明書 | cert-manager v1.21.1 / Let's Encrypt / RSA 2048 / `*.gke.shukawam.me` |

### 当面の Argo CD へのアクセス

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# → http://localhost:8080

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 解消したら

修正版の Kong Operator に上げたあと、**オペレータ Pod の再起動が必要**な点に注意する
（上記 2 の理由）。

```bash
kubectl rollout restart deploy/kong-operator-kong-operator-controller-manager -n kong
```

### 他に取り得る選択肢（未採用）

- `Gateway` から HTTPS listener を外し HTTP のみで公開する。ルーティングは復活するが TLS を失う
- `kong/kong-operator` を `1.4.0-rc.2`（app 2.3.0-rc.3）に上げて試す。
  CHANGELOG に該当記載はないため確度は低い

---

## 2. TLS Secret には `konghq.com/secret: "true"` ラベルが必要（解決済み・再発防止のため記録）

Kong Operator は Secret の informer キャッシュを `konghq.com/secret=true` で絞り込んでいる。
このラベルが無い Secret はオペレータから**一切見えず**、`Gateway` の listener が
`InvalidCertificateRef`（`Secret ... not found`）のまま永久に止まる。
`kubectl get` では取得できるため発覚しにくい。

`platform/kong-gateway/certificate.yaml` の `spec.secretTemplate.labels` で付与している。
cert-manager が発行する Secret に手で付けても、cert-manager が `secretTemplate` から
再適用するため、Certificate 側で指定する必要がある。
