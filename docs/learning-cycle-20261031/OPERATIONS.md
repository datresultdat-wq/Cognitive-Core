# 本番未適用・承認用の実施手順

対象は datresultdat-wq/Cognitive-Core、新Supabase wllbmvnimempkqzgshsi、Worker yuna-cogcor-v2 のみ。旧YUNAのアクセスを必要としない。

## 現在の境界

この変更はローカルのみ。Cronは本番で既に1本（*/5 * * * *）あり、今回追加・変更していない。auto_enabled=trueも変更していない。09:00 JSTにevent 20を処理した既存ジョブを読み取り確認した。推論完了は判断改善の証拠ではない。

新コードは既存Cronで新しい適格イベントを順次選ぶ方式。新Cronも即時Webhookも追加しない。最短遅延は既存Cron周期に依存する。登録後2分の猶予がある。対象はarmed時刻以降のuser_direct/observed_resultで、quote付きのconversation_event/learned_rule/open_thread。summaryは変換しない。過去の未処理記録を対象にする場合は、別途明示的な範囲確認が必要。

## 切替前の必須確認（まだ実行しない）

1. しんたが差分・停止時間・予算・ロールバックを承認する。GitHub master更新はCloudflare Buildsで本番デプロイを起動し得るため、承認前にpush/mergeしない。
2. 新環境だけの最新Worker version/bundle、全設定（Secretは値を出さず名前とbinding）、DO ID、Cron、Git HEADを再取得。今回の保存済みbundleとSHAを照合する。本番が動いていれば改めて差分を取る。
3. Supabaseの対象関数定義/ACL、テーブルDDL/制約/RLS/インデックス、control、queue、job_runs/job_stages、対象候補/skill/outcomeの復元可能なバックアップを作成し、保存権限と復元手順を確認する。今回の保存はコード・定義・メタデータ中心であり、全DBバックアップの代替ではない。Secretや本人の会話原文をGitへ入れない。
4. 承認済みの保守操作で既存Cronとautoを停止し、実行中/予約中ジョブがないことを確認。失敗・期限切れなら、stage/queue/候補/費用予約を照合して状態を確定する。行を消して再実行可能にしない。
5. `supabase/migrations/20261030225726_continuous_learning_contract.sql` を適用する。トランザクションと3秒ロック待ち、実行中/予約中ガードあり。新予算は未承認、autoはOFFで作成。既存RLS/Secret/Essenceは変更しない。
6. SQL受け入れ確認後にWorkerを反映。DB前のWorker反映は禁止。DO binding、migration tag v1、Secret、既存Cronを差分照合。ローカルwranglerにはCronがないので、無確認のdeployで本番設定を上書きしない。Buildsの設定を事前に調整するか、承認した単一のデプロイ経路を使う。
7. /health、未認証401、認証済みtools/list、読み取りRPC、合成データによる隔離テストを実施。認証値を出さない。本番本人データを検証の都合で書き換えない。
8. 本番推論は別途、対象イベント/モデル/最大入力6000bytes/出力512tokens/呼出上限/期限/最大費用を示して承認。費用上限は料金表と最大トークンから保守的に算定し `cost_per_call_ceiling_usd` を設定する。これは予約上限であり請求実績ではない。料金改定時に再審査する。現時点の設定0は実行を許可しない。

## 停止・再開の契約

- event、run、approval単位のユニーク制約。controlの行ロックで予約/claimを直列化する。
- rolling 1時間/24時間の呼出数と最大費用予約をreserve/claim両方で検証。失敗分も消費扱い。UTC日跨ぎで予算をリセットしない。daily_limitは隔離test専用に残る。
- 予約4分以内にclaim。claim後は10分リース、stage書き込みは開始9分以内。AI待ちは45秒で打ち切り、推論自体のキャンセルを保証せず、その予約費用は返さない。
- 本番の自動再試行は0。失敗/部分完了/期限切れ/候補滞留で停止。呼出・費用予算不足は待機、期限切れ予算は再承認が必要。
- 異常停止後は、人が原因・書き込み済み成果物・費用台帳を照合し、問題を解消し、未解決running/approvalを明示的に確定するまで再armしない。同じeventをqueue/ledgerから削除して再試行しない。新しい証拠が必要なら出典付きの新イベントを別途審査する。
- 最初の運転再開は低い予算で監視。日次上限の数字変更だけで開始しない。Cronの重複追加は禁止。

## ロールバック

承認済み保守でCron/autoを止め、running/予約を照合してから `rollback.sql`。旧関数を復元し、新経路をservice_roleから閉じる。新テーブル・履歴・スキル・記憶は削除しない。元Worker version `63a60375-3db3-4591-8584-85b3005c252e` を復元し、Secret/DO/Cronを照合する。旧コードの検索時カウント問題も戻るため、学習利用・自動運転を停止したまま再修正する。armed状態を自動復元しない。

SQLロールバックは隔離DBで実行確認済み。本番のWorker rollback・復元演習は未実施。ロールバック後の再適用は既存新テーブルを残すので、この初回migrationを再実行せず前進修正を作る。

## ローカル再検証

```
npm ci
npm run check
npm ci --prefix scripts/local-db --ignore-scripts
node scripts/test-learning-db.mjs
./node_modules/.bin/wrangler deploy --dry-run --outdir /tmp/cogcor-review-build
```

SQLテストはPGlite/PostgreSQL WASM・ローカルメモリ上のみ。合成データを使用し、ネットワーク/AI呼び出し0。vectorはtext置換でembedding動作を検証しない。加えてMac上の隔離PostgreSQL 18.4で8接続による競合試験を実施し、同時適用の加算消失なし、同時観測評価の加算消失/デッドロックなし、重複Cron/claimでrunと費用予約が1件となることを確認した（計17シナリオ）。SQLのロック順序はreview→application→skill。実Cloudflareの複数Worker同時実行、実請求値の確認は未実施。

## Native PostgreSQLの追加試験

macOS arm64で、隔離した `/tmp/cogcor-nativepg-20261031` に `@embedded-postgres/darwin-arm64@18.4.0-beta.17` と `pg@8.13.1` を取得。通常の依存には追加していない。取得元は [embedded-postgres](https://github.com/leinelissen/embedded-postgres)。`--ignore-scripts`で取得後、内容を確認したhydrate-symlinks.jsだけをそのパッケージ内で実行した。

`node scripts/test-learning-native.mjs` は一時clusterを作り、権限0700のUnix socketだけで接続、TCPは無効、終了時にpg_ctlで停止する。合成データのみ。既存DBを接続先として指定できない。fixtureはpgvectorをtextへ置換しているためembedding検索の試験ではない。
