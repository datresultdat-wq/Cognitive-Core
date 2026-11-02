# 新CogCor v2 継続学習・会話還元：ローカル実装報告

2026-10-31。**今回の変更は本番未反映。最終合格条件である別チャットの実判断改善は未検証。** 本番変更・推論の承認は今回取得していないため、push/merge/SQL適用/deploy/本番AI実行は行っていない。

## 1. 正式ソースとGit

対象remoteは https://github.com/datresultdat-wq/Cognitive-Core 。origin/masterは `a48de5c37dd16ab5ad750a9661113d22d59dce46`（PR #6 merge）。元作業ツリー `/tmp/cogcor-learning-work-20261030` を保護し、`/tmp/cogcor-cycle-work-20261031` の `feature/learning-feedback-contract-20261031` で作業した。元の未追跡supabase/.tempをコミットしていない。今回のローカルコミットIDは同梱manifestを参照。

## 2. Cloudflare本番との差分

本番version `63a60375-3db3-4591-8584-85b3005c252e`、100%、2026-10-31 06:37:37 JST。取得bundle SHA-256 `5f9a29cf85b229049cb8fb8907858c9cb81b953117a4cf74ac4505027f2aab4e` は、前回保存済みビルドとbyte単位で一致した。ローカルを根拠なく上書きしていない。

本番Cronは既に `*/5 * * * *` が1本ある。ローカルwranglerにはCron定義がない。これは要照合の設定差分で、今回変更していない。Worker名、DO binding、Secret名は維持。新コードのdry-runは成功、本番へアップロードなし。

## 3. Supabase最新状態

11月2日08:28 JSTの再確認: masterとWorker versionは上記から変更なし。Cronは1本、auto_enabled=true、予約なし。moments 25、reflections 2、pending候補2、active skills 10、使用履歴あり0、outcomes 0。本番jobは引き続き2件で、10月31日09:00以降の新規完了は増えていない。以下は10月31日の確認記録。

13:23 JST: moments 24、reflections 2、pending候補2、active skills 10、使用履歴ありactive skills 0、outcome_scores 0、完了本番job 2。

09:00:14〜09:00:16 JSTにevent 20のjob `e7167d4a-2977-489e-9371-03926ccdccc0` が完了。claim/context/self_model_review/inference/reflection/metacognition/candidate各stage完了、queue完了、候補1件生成を確認した。既存Cron/auto制御経由の完了と整合するが、trigger_sourceがmanual_approvedなので、記録単体から経路を厳密に区別できない。12:09時点でauto_enabled=true、auto_last_status=completed、予約なし。こちらから実行したjobではない。

関連関数13個、列定義123件、制約/ACLを読み取り取得。全DBの復元用バックアップは未取得で、適用前に別途必要。RLS INFO 10件は依然存在し、ポリシー追加なし。

## 4. 根本原因

- reserve/claimが異なる固定UTC日次条件を持ち、日付跨ぎと処理能力の設計が不整合。
- 予約4分と実行lease10分を一つの期限として扱う部分があった。
- 自動claimがmanual_approvedを記録し、経路監査ができなかった。
- 検索でtimes_usedを増やし、非await/read-modify-writeのため実適用と混同し競合で消失し得た。boolean結果APIも使用数を増やしていた。
- 汎用score_outcomeと学習候補評価は別契約。候補→審査→skill→適用→観測の関連付けがなかった。
- 空白区切り検索の過度なAND条件。既存384次元embeddingにはモデル空間の来歴不足があり、別モデルを安易に混合できない。

## 5. 実装内容・ファイル

- `src/learning-contract.ts`: 対象project/RPC allowlist、秘密値を返さないHTTP失敗、10秒RPC期限、45秒AI待機上限。
- `src/index.ts`: match_skillを審査済み手順の取得に接続、検索時加算/embedding呼出を廃止。learning_search/application追加。booleanのみのlegacy評価を拒否。isErrorを監査失敗として計上。汎用target_typeを拡張していない。
- `src/pseudo-daemon.ts`: 対象主題に関連する観測評価だけを取得し、AI期限と固定エラーコード保存を追加。
- `supabase/migrations/20261102011543_continuous_learning_contract.sql`: 呼出/費用予約、event冪等性、reserve/claimの共通予算、期限整合、失敗停止、監査、審査/適用/観測/評価、検索正規化とOR/類似候補、service-only RPC。既存RLS/Essence/本人記憶は変更しない。
- `scripts/test-learning-db.mjs`、`scripts/test-learning-native.mjs`、`scripts/local-db/*`、`test/fixtures/*`: 隔離SQL試験。
- `test/learning-contract.test.ts`、`test/native-cognitive-loop.test.ts`: MCP契約/認証失敗/timeout/誤加算拒否。
- `.github/workflows/learning-check.yml`: 外部接続・本番Secretを使わないCI。GitHub上では未実行。
- `docs/learning-cycle-20261031/*`: 依存監査・承認前手順・ロールバック・受け入れ手順。

審査済み手順も本人事実や実効性検証済み事実とは区別する。既存10skillsやconfidence=0.3候補を自動採用していない。採用/評価RPCはWorker service_roleから実行不可で、人の明示確認を伴う管理経路のみ。

## 6. マイグレーションとロールバック

[OPERATIONS.md](OPERATIONS.md) と [rollback.sql](rollback.sql)。適用はtransaction/lock timeout/予約・実行中guardあり。予算は初期0・期限なし、auto停止。既存履歴を消さない。roll backは旧関数を復元し新経路を閉じ、データを保持する。SQL rollbackは隔離DBで実行確認。Worker復元演習は未実施。

費用・稼働再開・本番本人データを使うテストは別途承認。既存Cronを複製しない。現在の稼働中設定を無断でOFFにもしていない。

## 7. テスト結果と失敗の扱い

- Mac `npm ci`: 成功。依存監査指摘は残存。
- `npm run check`: 256/256成功。型検査は既知TS2416（agents/SDK二重依存）1件を既存allowlistで許容。新規型エラー0。完全なtscエラー0とは報告しない。
- PGlite: 14シナリオ成功。PostgreSQL 18.4 native: 同じ14＋8接続競合3＝17シナリオ成功。14と17は重複を含み、31個の独立試験ではない。
- 8接続の同時適用、同時評価、重複Cron/claimにおいて加算消失なし、観測評価デッドロックなし、費用予約/runは1件。
- 同一event/approval再送、summary除外、期限切れ、呼出/費用制限、候補バックログ、失敗停止、権限拒否、引用保存、正負評価、観測前評価拒否、rollbackを確認。AI不正JSON/API失敗/認証失敗/timeoutはモックで確認。本番推論0。
- 合成日本語9クエリ/8記録: Precision 1.00→1.00、Recall 0.50→1.00、誤陽性率0→0。小規模・固定例で、実会話全体の品質保証ではない。
- dry-runビルド、git diff --check成功。

途中失敗: SQLの括弧/関数終端の構文、追加コードの型エラーを修正。保留後採用時のskill_id欠落を修正。テストが既存usage_logs通信を業務RPCとして数えていた期待値を修正。native試験の合成入力重複を修正。npm取得/共有メモリ/ログ書込のsandbox拒否は許可後に再実行。未解消の失敗を成功数へ混ぜていない。

## 8. 本番反映の区別

今回の実装、SQL、CI、PR/merge、deployは全て未反映。09:00のevent20完了は以前から動いている本番版の動作。現在の本番が新しい審査・適用・評価経路を持つとは報告しない。

## 9. 残存リスク・費用

[DEPENDENCIES.md](DEPENDENCIES.md) に27指摘の直接/間接/深刻度/bundle含有/修正影響を記録。critical proxy-addrはWorker bundle非含有。SDK/agents/zod等は含まれ、個別到達性の完全な侵入試験は未実施。強制更新は行っていない。

新しい検索は追加AI課金0。daemon推論は入力/出力/回数/費用予約/期限で制限するが、上限単価の承認と実請求照合が必要。AI timeoutはサーバー側処理の取消保証ではなく、その費用予約を消さない。本番自動再試行は0。DB監査件数と検索負荷は増えるため運転時に観測する。

実Cloudflare複数Worker、Supabase実権限でのE2E、意味検索/多言語embedding、媒体構造化、実会話でのPrecision/Recall、別チャットの実適用・改善は未検証/未完了。モデルに検索を強制する任意のChatGPT公式フックはない。正規のツール接続と明示的な検索依頼で補う。

## 10. 通常文字ユナでの受け入れ

[ACCEPTANCE.md](ACCEPTANCE.md) にA〜Jの手順と判定表を記録。別チャットで取得→選択→実際の回答適用→本人の後日観測→管理経路で評価→次の判断を比較する。最終合格はこの実証が揃ってからであり、現時点では未完成。
