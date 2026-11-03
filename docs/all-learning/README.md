# Continuous provisional learning

One rollout covers capture, expanded analysis, an active-learning prompt, provisional application/correction, and chat recall.

## Actual capture boundary

`capture_experience` / `cogcor_learning_capture_v1` wraps existing `cogcor_chat_bridge.remember`. It records conversation/message references, optional original timestamp (null when unavailable), capture timestamp, evidence and real/hypothetical/fiction context. Stable message receipts and a content-level lock prevent repeat saves across chats/days. Existing matching memory is linked, not replaced. A message reference must identify the actual source; do not reuse a reference for changed text.

The Worker does **not** receive every ChatGPT message. This deployment cannot add an arbitrary hook to the official app. The model must select capture/search tools, or use the connected Supabase plugin's execute_sql to invoke the same public RPCs. A connected account and successful manual read do not prove automatic invocation. Do not claim inaccessible conversations were captured. Do not insert diagnostic instructions as user experiences.

Official connection/selection documentation: https://developers.openai.com/api/docs/guides/custom-mcp-server

## Analyze, use, correct

All five existing memory kinds and four evidence classes are eligible. Storage bounds remain 1600 characters / 800-character quote; the old processing filter of 20–1200/5–500 is removed. The model input is bounded to 6000 UTF-8 bytes (source excerpts can be truncated and are labeled), output to 512 tokens, one fixed-model call and no retry. No increase to the $0.001 per-job reservation or lifetime $3 cap. Already processed events are not requeued; the armed-period boundary is retained.

Prompt: first identify supported understanding and future usefulness. Distinguish testimony, third-party report, interpretation, fiction and conjecture. Null outputs remain legal for duplicates/no supported new insight. Original memories remain available in full through search; the prompt receives bounded excerpts.

`match_skill` now calls `cogcor_learning_provisional_context_v1` and returns reviewed skills, source-bearing provisional candidates, memories and corrections. Use a small set of meaningful Japanese keywords; lexical matching is not semantic proof. Provisional candidates join a completed production job to real source records, exclude formal reviews and held/corrected hypotheses, and are never promoted to fact/Essence. No new embedding calls.

`provisional_application` records retrieved -> selected -> applied -> outcome_observed. Searches themselves create no application/counter. Use a stable UUID and actual answer reference. Retries are idempotent and changed evidence conflicts fail. Observations must come later from direct/observed sourced events; fiction cannot score a real-world outcome. Operator-only `scored` accepts helped/not_helped/uncertain with a quote from the observed source. This remains a sourced evaluation, not objective proof of improvement. Formal review_v2 and existing skill evaluation stay separate.

`correct_provisional_learning` links an explicit current direct user correction to a specific candidate. The old hypothesis is held for provisional use without deleting or rewriting it. Context returns the correction prominently. New corrections can be analyzed as new events; the old event is not retried. Current user statements outrank previous hypotheses. A client must actually invoke this linkage; backend cannot infer an unseen correction.

## Available Supabase route for normal Yuna

Only project wllbmvnimempkqzgshsi. Use execute_sql with:

- `SELECT public.cogcor_learning_capture_v1(conversation_ref,message_ref,original_time_or_null,kind,content,quote,evidence_type,context_type);`
- `SELECT public.cogcor_learning_provisional_context_v1('short relevant keywords',5);`
- `SELECT public.cogcor_learning_provisional_apply_v1(application_uuid,candidate_uuid,conversation_ref,'retrieved');` then selected with applicability and applied with actual answer reference.
- `SELECT public.cogcor_learning_correct_v1(candidate_uuid,direct_correction_moment_id);`
- Later observation then operator scoring, only when real user evidence exists.

Use parameter binding/SQL quote escaping; never paste keys. These are authenticated service/operator RPCs, not anonymous endpoints. Selecting an app explicitly for an E2E test is an assisted test, not proof of spontaneous use in all chats.

## Rollout/rollback

Pause only auto_enabled; preserve approvals, leases, queue and failed jobs. Snapshot existing memories/Essence, skills/proposals/jobs, RPC definitions and control. Apply SQL while no active job/reservation, run local/CI checks, merge one PR and deploy yuna-cogcor-v2. Verify actual version, unchanged Secrets/DO, single existing Cron, budgets and source data. Resume only after verified deployment; observe newly eligible events once.

Rollback: pause, resolve active work, restore Worker 158b22b9-9e16-4358-adfb-4c246b033e9f and run rollback.sql. It restores the old eligibility RPCs and revokes new service entry points; added tables/evidence remain intact and closed. Budget history is retained. No deletion of prior records or automatic reactivation.

## Acceptance evidence

Separate: real conversation capture, job/candidate generation, new-chat retrieval, selection, actual answer application, later user correction/evaluation, and demonstrated improvement. Synthetic tests and agent-written summaries are never substituted for user observations. Production example contents belong in private audit evidence, not in this repository.
