# Optional learning outputs

A saved experience need not produce a reflection, candidate, or self-model question. The AI contract is a JSON object with each of those fields containing a nonempty bounded string or null. Individual fields may be omitted. An empty object, unknown-only object, malformed JSON, blank string or wrong type remains invalid. Extra fields are discarded. All-null means the experience is already stored and needs no additional learning output; it does not cause another memory write.

Only present validated fields enter native write handlers. Missing outputs have explicit `skipped` stage receipts. A candidate may have a null question, but never null/blank content. Candidates stay pending at confidence 0.3; no automatic adoption. All outputs are validated before the first native write. Field error receipts contain only allowlisted field names and validation codes, never rejected values or Zod messages.

The finalizer verifies the accepted inference receipt's generated fields against each completed/skipped stage. A generated candidate requires the existing sourced pending proposal. An omitted candidate requires an explicit skipped stage and absence of a proposal. Successful processing is not evidence of learning effectiveness.

## Production rollout and rollback

Target only Supabase wllbmvnimempkqzgshsi and Worker yuna-cogcor-v2.

1. Snapshot control, active jobs/approvals/queue, function definitions/ACLs, data hashes and Worker version. Set only auto_enabled=false under the control row lock. Let an existing job resolve; never clear an unresolved approval or retry a failed event.
2. Apply the new optional_learning_outputs migration while disarmed and quiescent. It replaces four existing RPCs, preserves signatures/ACLs and does not update memories, skills, RLS, budget or reservation history.
3. Merge the tested Worker change and verify the actual deployed version. Preserve Secrets, Durable Object bindings and the existing single five-minute Cron schedule.
4. Verify SQL definitions, ACLs, data integrity and authenticated/non-authenticated routes. Re-enable only auto_enabled after checking for failures since auto_started_at and no unresolved reservation. Keep the armed-period boundary and cumulative accounting; do not retry moment 35.
5. Observe a new eligible sourced experience through the normal Cron path. If none exists, report awaiting new experience rather than success. On any failure, retain the automatic stop and investigate.

Rollback: disable automatic reservations, wait for/inspect in-flight work, restore Worker version 69d7ff13-65d5-4505-91b8-72a8f6978fdf and execute rollback.sql while quiescent. It restores only the four pre-change RPCs and leaves auto disabled. It does not undo the cumulative budget or remove learning records. Never automatically resume the old mandatory-output implementation.

## Cumulative budget history

20261102071515 is an exact backfill of the migration already applied by the operator on November 2. Do NOT execute it again in production. Its operational guard expects a quiescent armed control row. The local test harness reproduces that historical prerequisite in isolated synthetic data and immediately disarms before applying the new migration.

The live policy reserves $0.001 per production job against a lifetime $3 cap, including failed and legacy jobs. Old daily/hour/backlog fields remain for compatibility but are not active production limits. The new migration does not alter that policy. Local tests assert no daily-one restriction and no midnight reset. This application-side reservation is not a Cloudflare account-wide billing cap; unrelated usage is outside it.

## Validation

npm ci; npm run check; node scripts/test-learning-db.mjs; node scripts/test-learning-native.mjs; git diff --check. Synthetic tests never invoke AI or a remote DB. Known TS2416 is tracked by the existing typecheck script, independently of new type failures.

Verified on Mac: 267 Vitest tests; 28 isolated SQL scenarios; 32 native PostgreSQL scenarios including 8-connection concurrency. SQL migration 20261102103142 applied while disarmed; pre/post hashes of memories, skills, proposals, Essence and jobs matched, as did function ACLs. npm audit still reports the existing 27 advisories (1 critical, 16 high, 6 moderate, 4 low); no dependency changes.
