-- No AI requests. All fixture writes and temporary state changes roll back.
-- Run only on new CogCor v2. Existing memory rows are never modified or deleted.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='25s';
DO $$ BEGIN IF EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE auto_enabled OR enabled OR inference_approved OR manual_approval_id IS NOT NULL) THEN RAISE EXCEPTION 'Controller must be disarmed'; END IF; END $$;
-- Shift run dates only inside this rolled-back test transaction to test a fresh quota day.
UPDATE public.job_runs SET started_at=now()-interval '2 days' WHERE job_name='cogcor_pseudo_daemon_v1:production';
UPDATE cogcor_daemon_private.control SET namespace='production',auto_enabled=true,auto_started_at=now(),daily_limit=1,enabled=false,inference_approved=false,manual_approval_id=NULL,manual_moment_id=NULL,manual_approval_expires_at=NULL,auto_approval_id=NULL,auto_moment_id=NULL,auto_reserved_at=NULL WHERE id;

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_enabled=false WHERE id; IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='disarmed') THEN RAISE EXCEPTION 'disarmed'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: disarmed

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
IF NOT (public.cogcor_daemon_auto_reserve_v1(NULL)->>'status'='invalid_tick') THEN RAISE EXCEPTION 'null_tick'; END IF;IF NOT (public.cogcor_daemon_auto_reserve_v1(now()-interval '11 minutes')->>'status'='invalid_tick') THEN RAISE EXCEPTION 'old_tick'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: invalid_tick

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='no_eligible_new_event') THEN RAISE EXCEPTION 'no_eligible_new_event'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: no_event

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET daily_limit=2 WHERE id; IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='misconfigured') THEN RAISE EXCEPTION 'misconfigured'; END IF; IF NOT ((SELECT NOT auto_enabled FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'misconfig_not_disarmed'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: misconfigured

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET enabled=true WHERE id; IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='busy_or_pending_approval') THEN RAISE EXCEPTION 'busy_or_pending_approval'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: manual_busy

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
INSERT INTO public.job_runs(job_name,status,trigger_source) VALUES('cogcor_pseudo_daemon_v1:production','completed','rollback_test'); IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='daily_limit') THEN RAISE EXCEPTION 'daily_limit'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: daily_limit

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
INSERT INTO public.job_runs(job_name,status,trigger_source) VALUES('cogcor_pseudo_daemon_v1:production','failed','rollback_test'); IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='paused_after_failure') THEN RAISE EXCEPTION 'paused_after_failure'; END IF; IF NOT ((SELECT NOT auto_enabled FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'failure_not_disarmed'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: previous_failure

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
INSERT INTO public.job_runs(job_name,status,trigger_source,started_at) VALUES('cogcor_pseudo_daemon_v1:production','running','rollback_test',now()-interval '1 hour'); IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='paused_running_job') THEN RAISE EXCEPTION 'paused_running_job'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: stale_running

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
INSERT INTO public.job_runs(job_name,status,trigger_source,started_at) VALUES('cogcor_pseudo_daemon_v1:production','completed','rollback_test',now()-interval '1 day') RETURNING id INTO r;
INSERT INTO public.cognitive_proposals(proposal_type,proposed_content,rationale,source_records,job_run_id) SELECT 'orphan','SYNTHETIC ROLLBACK ONLY','learning_candidate','[{"table":"rollback_only","id":"synthetic"}]'::jsonb,r FROM generate_series(1,5); IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='paused_candidate_backlog') THEN RAISE EXCEPTION 'paused_candidate_backlog'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: candidate_backlog

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES
(-90005,now()-interval '1 day','conversation_event','observed_result','SYNTHETIC OLD BACKLOG ONLY','SYNTHETIC QUOTE','chatgpt_yuna_normal'),
(-90004,now()-interval '3 minutes','conversation_event','assistant_interpretation','SYNTHETIC INTERPRETATION ONLY','SYNTHETIC QUOTE','chatgpt_yuna_normal'),
(-90003,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC EMPTY QUOTE ONLY',' ','chatgpt_yuna_normal'),
(-90002,now(),'conversation_event','observed_result','SYNTHETIC TOO RECENT ONLY','SYNTHETIC QUOTE','chatgpt_yuna_normal');
g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;
IF NOT ((SELECT manual_moment_id=-90001 AND auto_moment_id=-90001 AND manual_approval_expires_at>now() FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'wrong_event'; END IF;
IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='busy_or_pending_approval') THEN RAISE EXCEPTION 'busy_or_pending_approval'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: eligibility

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;UPDATE cogcor_daemon_private.control SET auto_reserved_at=now()-interval '5 minutes' WHERE id; IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='paused_unfinished_reservation') THEN RAISE EXCEPTION 'paused_unfinished_reservation'; END IF;
IF NOT ((SELECT NOT auto_enabled AND NOT enabled AND NOT inference_approved AND auto_approval_id IS NOT NULL FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'lease_not_locked'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: unfinished_lease

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;IF NOT (public.cogcor_daemon_auto_finalize_v1(gen_random_uuid(),true)->>'status'='approval_mismatch') THEN RAISE EXCEPTION 'wrong_approval'; END IF;IF NOT ((SELECT auto_approval_id=a FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'other_approval_cleared'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: mismatch

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;IF NOT (public.cogcor_daemon_auto_finalize_v1(a,false)->>'status'='disarmed') THEN RAISE EXCEPTION 'not_disarmed'; END IF;IF NOT ((SELECT NOT auto_enabled AND NOT enabled AND NOT inference_approved AND auto_approval_id IS NULL FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'failure_flags'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: failed_finalize

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;INSERT INTO public.job_runs(job_name,status,trigger_source) VALUES('cogcor_pseudo_daemon_v1:production','completed','manual_approved');IF NOT (public.cogcor_daemon_auto_finalize_v1(a,true)->>'status'='disarmed') THEN RAISE EXCEPTION 'unrelated_success'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: unrelated_completion

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
UPDATE cogcor_daemon_private.control SET auto_started_at=now()-interval '5 minutes' WHERE id;
INSERT INTO cogcor_chat_bridge.moments(id,recorded_at,memory_kind,evidence_type,memory_content,source_quote,origin) OVERRIDING SYSTEM VALUE VALUES(-90001,now()-interval '3 minutes','conversation_event','observed_result','SYNTHETIC ROLLBACK ONLY observation evidence','SYNTHETIC QUOTE ONLY','chatgpt_yuna_normal');g:=public.cogcor_daemon_auto_reserve_v1(now()); IF NOT (g->>'status'='approved') THEN RAISE EXCEPTION 'not_approved'; END IF; a:=(g->>'approval_id')::uuid;
g:=public.cogcor_daemon_claim_v1(now(),false,a);
IF NOT (g->>'status'='claimed') THEN RAISE EXCEPTION 'claim_failed'; END IF; r:=(g->>'run_id')::uuid;
PERFORM public.cogcor_daemon_stage_v1(r,'inference','completed','{"validation":"accepted","test_fixture":true}');
PERFORM public.cogcor_daemon_candidate_v1(r,'SYNTHETIC ROLLBACK ONLY candidate','SYNTHETIC ROLLBACK ONLY question');
PERFORM public.cogcor_daemon_finish_v1(r,'completed',NULL,false);
IF NOT (public.cogcor_daemon_auto_finalize_v1(a,true)->>'status'='completed') THEN RAISE EXCEPTION 'bound_success_failed'; END IF;
IF NOT ((SELECT auto_enabled AND NOT enabled AND NOT inference_approved AND auto_approval_id IS NULL AND auto_moment_id IS NULL FROM cogcor_daemon_private.control)) THEN RAISE EXCEPTION 'not_finalized'; END IF;
IF NOT ((SELECT attempts=1 AND status='completed' FROM cogcor_daemon_private.queue WHERE namespace='production' AND moment_id=-90001)) THEN RAISE EXCEPTION 'duplicate_attempt'; END IF;
IF NOT (public.cogcor_daemon_auto_reserve_v1(now())->>'status'='daily_limit') THEN RAISE EXCEPTION 'daily_limit'; END IF;
IF NOT (public.cogcor_daemon_claim_v1(now(),false,a)->>'status'='disabled') THEN RAISE EXCEPTION 'approval_reused'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: completed_bound_event

SAVEPOINT scenario;
DO $test$ DECLARE g jsonb; a uuid; r uuid; BEGIN
IF NOT (NOT has_function_privilege('anon','public.cogcor_daemon_auto_reserve_v1(timestamptz)','EXECUTE') AND NOT has_function_privilege('authenticated','public.cogcor_daemon_auto_finalize_v1(uuid,boolean)','EXECUTE') AND has_function_privilege('service_role','public.cogcor_daemon_auto_reserve_v1(timestamptz)','EXECUTE')) THEN RAISE EXCEPTION 'public_access'; END IF;
END $test$;
ROLLBACK TO SAVEPOINT scenario;
RELEASE SAVEPOINT scenario;
-- Passed: permissions

ROLLBACK;
SELECT 16 AS scenarios_passed, enabled,auto_enabled,inference_approved FROM cogcor_daemon_private.control;

