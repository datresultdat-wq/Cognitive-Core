# 通常文字ユナでの受け入れ確認（本番実施は別途承認）

最終合格は「別チャットの回答で過去の訂正を適用し、同じ失敗が減ったことを本人が観測した」証拠が揃うこと。推論、保存、検索、自己申告のappliedだけでは合格にしない。

## 接続の現実的な境界

このCodex環境では接続済みSupabase execute_sqlの読み取り経路を確認できたが、通常文字ユナ専用CogCor MCPツールは列挙されなかった。通常文字ユナの別チャットにどのツールが出るかは、そのチャットで確認する必要がある。公式ChatGPTアプリに任意の自動フックは追加していない。

Workerの認証済み `/mcp` で tools/list に match_skill / learning_search / learning_application が出ることを、承認済みデプロイ後に確認する。接続できない場合は接続済みSupabaseから `SELECT public.cogcor_learning_context_v1('主題',5)` と `SELECT * FROM public.cogcor_learning_search_v1('主題',5)` を使う。service keyを会話へ貼らない。権限が不足したらRLSや公開権限を広げず接続設定を見直す。

検索が必要な目安は「本人に訂正された主題」「継続課題」「前回の失敗への再挑戦」「本人の明示的な検索依頼」。通常の雑談で毎回呼ぶ設定にはしない。この条件はモデルのツール選択依存で、外部システムは呼び出しそのものを保証できない。代替は、継続課題の開始時に本人が明示的に「CogCorの訂正・手順を確認して」と依頼する運用。より強い保証にはユーザーが選択する独自クライアントが必要で、今回追加していない。

## A〜Jの実行

A. チャットAでしんたが小さな実際の訂正を述べ、保存に同意。既存 remember に原文quote・user_direct・出典を渡す。返却memory_sourceと元メッセージを照合する。合成テストなら本番momentsへ入れず隔離DBで行う。

B/C. 対象event、予算、期限、送信内容を承認後、対象が適格であることを確認。既存の単一Cronで処理する場合は新Cronを追加しない。queue/ledger/jobを確認してeventに1件だけ対応することを確認する。失敗時に再推論しない。

D. inference/stage/candidate/source_recordsを照合。候補はまだ仮説。生成できたことを学習効果と記録しない。

E. 全active skillのID・手順を比較し、出典、重複、矛盾、適用条件、期待改善を人が審査。明示的な承認発言を別イベントとして保存する。postgres権限の承認担当者が `cogcor_learning_review_v1(candidate_id, review_event_id, 'approved', conditions, expected_improvement, comparison_notes, compared_skill_ids)` を実行する。WorkerはこのRPCを呼べない。保留/却下/無効化も同じ審査経路で記録。confidence=0.3候補は無条件採用しない。既存10skillsは新制度の審査済み扱いにしない。

F. 別チャットBで、以前と異なる言い回しの同じ種類の課題を依頼。match_skillの返却に対象skill、元event、review_event、evidence_type、quoteがあることを確認。検索ログだけで適用を認定しない。

G/H. UUIDを1つ生成し、同じapplication_idと不透明なconversation_refで `learning_application` のretrieved→selectedを順に記録。selectedのevidenceは今回適合する理由。実際の回答で手順を使った後だけappliedに進め、その回答の参照IDをevidenceに渡す。検索しただけならretrievedで止める。times_usedはappliedへ初回遷移した時だけ増える。legacy update_skill_outcome とREST boolean評価は409/明示エラーになり、件数を変えない。

I. しんたが回答を確認し、何が改善/失敗したかを述べる。回答後の直接発言・観測記録として保存し、元メッセージを照合。applicationのoutcome_observedにそのeventを関連付ける。人による確認後にpostgres権限の担当者が `cogcor_learning_score_v1(application_id, helped)` を実行する。AIの自己評価のみで実行しない。重複は件数不変、異なる再評価はエラー。負の結果は手順をheldにして次のmatchから外す。

J. さらに後日の同種課題で同じ失敗が減ったか、実回答と本人観測を比較する。新applicationを作り、観測/評価を再度行う。負の結果や不適合を除外せず保存する。審査済みというラベルは「効果検証済み」ではない。本人事実への昇格はしない。

## 判定表

|項目|ローカルで確認した範囲|本番・別チャット|
|---|---|---|
|A|既存remember、引用保存、同一記録の冪等性|今回未実施|
|B/C|適格判定、summary除外、予約/claim重複、予算、リース|旧版event20完了のみ。新版未実施|
|D|AI出力検証と失敗停止（モック）|旧版に候補2件。新版推論0回|
|E|審査権限、出典、不適格拒否、保留後採用|未実施|
|F/G|ツール引数契約とDB状態遷移|別チャット未実施|
|H|検索で加算なし、appliedの原子的加算、再送不変|新版未実施|
|I|観測前評価拒否、正負評価、二重評価拒否|未実施|
|J|負の結果による保留、関連評価だけの再学習文脈|実際の判断改善は未検証|

同時実行はMacの隔離PostgreSQL 18.4で8接続の競合まで確認済み。実Cloudflareの複数Workerでの競合試験は未実施。日本語検索は合成9クエリのみ。意味検索、多言語embedding移行、人物同名識別、媒体の構造化フィルタは未完成。384次元が同じでもMiniLMとbge-smallの空間は同じとは限らず、既存embeddingを混合して再評価していない。
