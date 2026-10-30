# Guarded automatic processing (deployed disarmed)

Target: `datresultdat-wq/Cognitive-Core`, Supabase `wllbmvnimempkqzgshsi`, Worker `yuna-cogcor-v2`. Old YUNA is out of scope.

## Deployment state

The migration `supabase/migrations/20261030171427_guarded_auto_learning.sql` is applied to the new project. All automatic fields start disarmed; this deployment does not install Cron or grant ongoing inference consent. The existing manual endpoint remains unchanged.

After separate user approval, a scheduled invocation can reserve one newly saved, sourced event. Reservation locks the control row and requires production namespace, daily_limit=1, an explicit start time and no active approval/running job. It excludes events before that start time, waits two minutes after capture, rejects assistant interpretations and missing quotes, and excludes any event already in the production queue. At five pending learning candidates, automatic processing pauses for review.

The model still receives at most 6,000 input UTF-8 bytes and 512 output tokens, one call without retry. One production run per UTC day is enforced in both reservation and claim; manual production runs count toward the same limit. These are usage limits, not a guaranteed monetary billing cap.

## Fail-stop behavior

Reservation grants expire in four minutes and are consumed before inference. Finalization requires the reserved event's completed queue/run, accepted inference receipt and sourced pending candidate. A different completed run cannot satisfy it. Run/initialization failures disarm; failed finalization leaves an outstanding reservation that blocks further work. A subsequent tick detecting an expired outstanding reservation explicitly disarms and retains the reservation for inspection. No automatic rearming or retry is implemented.

Candidate generation is not success at learning. Candidates stay pending and appear in recall as `learning_candidate_unreviewed`; neither identity/Essence promotion nor positive outcome recording is part of automatic processing. Capture is limited to moments actually saved to the new database, not all chat transcripts. A source_quote field is not proof of verbatim provenance; capture consent and accuracy still need review.

## Validation and remaining work

- Mac npm ci and npm run check: 250 tests / 15 files; existing SDK dependency-duplication type error remains explicitly allowlisted, no new type error.
- `test/auto-learning.integration.sql`: 16 real DB scenarios, all rolled back, no model calls. Includes quota, no event, invalid ticks, manual approval conflict, backlog, stale running job, unfinished reservation, unrelated completion rejection, finalization and privilege checks. It temporarily shifts job dates within the transaction to simulate a fresh quota day; it never modifies/deletes existing memory rows. Never run while armed.
- Wrangler dry-run and diff checks passed. Existing Secret, Durable Object, Essence, preferences and RLS remain unchanged.
- npm audit reports 27 existing dependency findings (4 low, 6 moderate, 16 high, 1 critical). Critical: transitive proxy-addr IP trust spoofing, GHSA-jqcg-44mw-7w3h. Dependencies/lockfile were not changed by this patch; dependency remediation requires separate regression review. This Worker uses Bearer authentication, not proxy-addr trust for daemon authorization.
- Actual later conversational use, observed judgment improvement and feeding that real evaluation into subsequent reflection remain unverified. The prior single production inference proves only generation/storage/recall. Do not declare automatic learning complete or enable Cron/auto_enabled based on these tests.

Operational stop: keep auto_enabled=false and enabled=false, clear unused approvals only after inspecting current runs; never erase uncertain run/queue receipts. Enabling the schedule and ongoing inference is a separate user decision after observed-outcome E2E validation and cost review.
