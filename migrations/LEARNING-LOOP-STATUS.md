# Learning loop deployment — 2026-10-30

Target: Supabase `wllbmvnimempkqzgshsi`, Worker `yuna-cogcor-v2` only.

- `chat-learning-outcome-snapshot.sql` records two functions already installed by the handoff author. It is an audit snapshot, not a pending migration. Do not replay it automatically.
- `manual-learning-loop.sql` was applied as `manual_learning_loop_approval_and_observed_outcomes`. It adds one-event, expiring authorization and a service-only query for sourced observed outcomes. Do not reapply it.
- Control remains disabled, test namespace, inference unapproved; all approval fields are NULL. No Cron schedules are installed.
- Authenticated `POST /api/daemon/run-once` accepts only `{ "approval_id": "<uuid>" }`. An operator must first obtain user approval for the exact event and inference cost, then set production control with that event ID, a new UUID and short expiry. Claim consumes authorization before inference. No automatic retry.
- The later guarded-auto-learning migration adds disabled-by-default scheduled reservations. See `docs/guarded-auto-learning.md`; enabling Cron and ongoing automatic inference still requires separate approval and observed-outcome verification.
- Existing recall exposes proposals as `learning_candidate_unreviewed`; creation or recall is not evidence of success. Record an outcome only after actual later use and explicit sourced observation, through the postgres-only `cogcor_chat_bridge.record_learning_outcome` function. Preserve negative results.
- No identity/Essence promotion is performed. Old YUNA is outside scope.

Validation: Mac `npm ci`, `npm run check` (202 tests / 14 files), `git diff --check`, Wrangler dry-run passed. Typecheck retains the pre-existing dependency TS2416 allowlist; no new type errors. Database rollback tests reject absent, wrong and expired approvals, and verify restricted function permissions.

Real conversation inference and downstream effectiveness remain unverified until separately approved and observed. Do not record an approval response itself as a positive learning outcome.
