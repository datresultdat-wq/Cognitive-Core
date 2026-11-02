# Human-approved rule registration

`cogcor_learning_review_v2` registers the exact revised procedure approved by a human, retaining the original AI candidate and evidence. The operator must supply an approval event recorded as `codex_user_approval` / `user_direct`; this is deliberately not represented as a normal Yuna conversation. All five rule fields must occur verbatim in the recorded approval quote, along with explicit adoption authorization. The trusted operator is responsible for authentic attribution; matching text is not identity authentication.

The operator compares every active skill. Each comparison includes its current complete-row MD5, a non-conflicting relationship and a reason. Registration locks skills, rejects stale/incomplete comparisons and exact duplicate titles/bodies, and snapshots comparisons. Semantic conflict assessment remains a human/operator responsibility, not an AI or database guarantee. Overlapping rules require a distinct scope and must not replace existing skills.

Original candidate, source evidence, approval evidence, revised fields, change rationale and comparisons are stored in an immutable private revision row. Revision 1 is supported; changing an already adopted body requires a separately reviewed extension, never an overwrite. Existing candidate content remains untouched; accepted_content holds the revised procedure plus exceptions. Existing review/application/outcome contracts remain compatible. Approval is not evidence of effectiveness. Counters remain zero until actual application and observation.

Only the database operator can invoke adoption. PUBLIC, anon, authenticated and service_role cannot invoke v2 or read the private revision snapshots. Existing RLS/policies, secrets and Worker configuration are unchanged. The additive private table has RLS enabled without public policies. No production AI call or Cron change is part of this feature.

## Cutover and recovery

1. Confirm the target new project and worker, disabled learning and no active jobs. Snapshot the relevant candidates, active skills, reviews, control, RPC definitions and protected-row hashes in a private local backup.
2. Run `npm ci`, `npm run check`, `node scripts/test-learning-db.mjs`; on Mac with the isolated PostgreSQL runtime, also `node scripts/test-learning-native.mjs`. Integration tests use synthetic data only.
3. Apply the additive SQL migration and record its actual server history version. Review/merge the PR after checks. Worker JavaScript does not change; the existing match_skill RPC path reads the registered skills without inference. A configured GitHub master build may redeploy identical Worker code.
4. In one bounded transaction, record only explicitly approved rule quotes with truthful origin; compare active skills; register authorized candidates; verify exact fields and provenance before commit. Retain the concrete registration transaction privately, not in GitHub.
5. Confirm repeat invocation returns the same skill IDs without another history record. Verify read-only search, unchanged old skills/source rows/Essence, disabled automation and zero application/outcome counters.
6. Recovery: `rollback.sql` removes only the new registration RPC. It preserves all evidence and registered skills. If a rule is faulty, separately hold only its candidate's review after inspecting actual applications; never erase records or restore an armed control state. Reapply the reviewed CREATE FUNCTION and its explicit REVOKE statements to restore registration. Do not rerun CREATE TABLE on an applied migration.

## Separate-chat acceptance

First verify an actual authenticated connection to the new Worker and tool availability. Search and inspect source ID, review state and conditions; pending hypotheses are not user facts. Use short keywords as well as natural language because long-query recall remains imperfect. Test-only scenarios must not be stored as personal experiences.

After permission to record the E2E, assign one application UUID and stable conversation reference. Record retrieved, selected (applicability evidence), applied (actual response reference), then outcome_observed only after a real later user observation. Score through the operator-only outcome RPC. Search alone must not count as use, and a correct answer without evidence of CogCor retrieval/application is not proof of this learning loop. Human observation of reduced recurrence is still required; tool selection in another chat is not guaranteed by the server.
