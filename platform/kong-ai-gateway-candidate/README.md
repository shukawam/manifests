# AI Gateway 候補版

`values.yaml` は `platform/kong-ai-gateway/values.yaml` に重ねる overlay。
現行版の KSA / Workload Identity と、Konnect に登録済みの証明書 Secret を参照する。
同じ CP・Redis を使うため、テストも実際の利用枠を消費する。

`apps/kong-ai-gateway-candidate.yaml` は自動同期しない。
Application の追加だけでは Deployment は起動しない。レビュー後に Argo CD で手動同期する。
Service `kong-ai-gateway-candidate-proxy:8000` は ClusterIP のみで、既存 HTTPRoute の宛先は現行版のまま。

初回は現行版と同じ `2.1.0` で A/A 比較する。新版は Renovate がこの overlay のタグにだけ PR を作る。
Renovate App / bot の有効化は別途必要。自動マージしない。
候補を検証後、現行 `platform/kong-ai-gateway/values.yaml` の更新を別 PR としてレビューする。

```bash
python3 -m pip install PyYAML==6.0.3
python3 scripts/validate-aigw-upgrade.py
# ダウンロード済みチャートならネットワーク不要:
python3 scripts/validate-aigw-upgrade.py --chart /path/to/kong-ai-gateway-0.1.0.tgz
```

検証は実際の Argo Application の values 順序からレンダリングする。
KSA、証明書の参照、Service selector、公開ルートの維持、readiness をチェックする。
チャート0.1.0は AI Gateway 2.xを古い Gateway と判定して `/status/ready` を `/status` に変換するため、
候補の probe にはクエリ文字列を加えてこの変換を避けている。

新旧 HTTP/SSE 比較・GitHub runner 設定・昇格と切戻しは
[minna-bank の運用手順](https://github.com/KongHQ-CX-JPN/minna-bank/blob/main/upgrade/README.md) を参照。
readiness の補正と drain 設定（grace 3630 秒、`kong quit --wait=15 --timeout=3600`）は現行 values に置き、候補 overlay はそれを継承する。
このスモークテストのみでは429、Redis残量継続、ガードレール拒否、監視基盤への到達を検証しない。

候補 Application に削除 finalizer はない。廃棄時は Argo CD でリソース削除を明示し、
Deployment / Service が残っていないことを確認する。
