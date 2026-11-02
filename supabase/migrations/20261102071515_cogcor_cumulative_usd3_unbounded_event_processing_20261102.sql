-- Exact backfill of already-applied production migration; do not rerun in production.

SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
 IF EXISTS (SELECT 1 FROM cogcor_daemon_private.control WHERE enabled OR inference_approved OR manual_approval_id IS NOT NULL OR auto_approval_id IS NOT NULL OR auto_reserved_at IS NOT NULL OR auto_moment_id IS NOT NULL)
 OR EXISTS (SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running')
 THEN RAISE EXCEPTION 'Unresolved active run or reservation; do not change budget policy'; END IF;
END $guard$;

ALTER TABLE cogcor_daemon_private.control
 ADD COLUMN IF NOT EXISTS total_cost_cap_usd numeric NOT NULL DEFAULT 0
 CHECK (total_cost_cap_usd >= 0);


CREATE OR REPLACE FUNCTION public.cogcor_daemon_budget_status_v1()
RETURNS text LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $budget$
DECLARE
 c cogcor_daemon_private.control;
 reserved_total numeric;
BEGIN
 SELECT * INTO STRICT c FROM cogcor_daemon_private.control WHERE id=true;
 IF c.total_cost_cap_usd<=0 OR c.cost_per_call_ceiling_usd<=0 OR c.cost_per_call_ceiling_usd>c.total_cost_cap_usd
 THEN RETURN 'budget_unapproved'; END IF;
 SELECT coalesce(sum(coalesce(r.cost_ceiling_usd,c.cost_per_call_ceiling_usd)),0)
   INTO reserved_total
 FROM public.job_runs j
 LEFT JOIN cogcor_learning_private.call_reservations r ON r.run_id=j.id
 WHERE j.job_name='cogcor_pseudo_daemon_v1:production';
 IF reserved_total+c.cost_per_call_ceiling_usd>c.total_cost_cap_usd THEN RETURN 'cost_budget'; END IF;
 RETURN 'ready';
END $budget$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_auto_reserve_v1(p_tick timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
 c cogcor_daemon_private.control;
 event_id bigint;
 approval uuid;
 budget_status text;
BEGIN
 IF p_tick IS NULL OR abs(extract(epoch FROM now()-p_tick))>600 THEN
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'invalid_tick'); RETURN jsonb_build_object('status','invalid_tick');
 END IF;
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id=true FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'control_missing'; END IF;
 INSERT INTO cogcor_learning_private.cron_ticks(tick) VALUES(date_trunc('minute',p_tick)) ON CONFLICT DO NOTHING;
 IF NOT FOUND THEN INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'duplicate_tick'); RETURN jsonb_build_object('status','duplicate_tick'); END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,status) VALUES('cron_triggered','received');
 IF NOT c.auto_enabled THEN INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'disarmed'); RETURN jsonb_build_object('status','disarmed'); END IF;
 IF c.namespace <> 'production' OR c.auto_started_at IS NULL OR c.auto_started_at>now() THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,auto_last_status='misconfigured' WHERE id=true;
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'misconfigured'); RETURN jsonb_build_object('status','misconfigured');
 END IF;
 IF c.auto_approval_id IS NOT NULL THEN
   -- A crashed runner/finalizer cannot silently acquire another event.
   IF c.auto_reserved_at IS NULL OR coalesce(c.auto_execution_deadline_at,c.auto_reserved_at+interval '4 minutes')<=now() THEN
     UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false,
       manual_approval_id=NULL,manual_moment_id=NULL,manual_approval_expires_at=NULL,
       auto_last_status='paused_unfinished_reservation' WHERE id=true;
     INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'paused_unfinished_reservation'); RETURN jsonb_build_object('status','paused_unfinished_reservation');
   END IF;
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'busy_or_pending_approval'); RETURN jsonb_build_object('status','busy_or_pending_approval');
 END IF;
 IF c.enabled OR c.inference_approved OR c.auto_moment_id IS NOT NULL OR c.auto_reserved_at IS NOT NULL
    OR c.manual_approval_id IS NOT NULL OR c.manual_moment_id IS NOT NULL OR c.manual_approval_expires_at IS NOT NULL THEN
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'busy_or_pending_approval'); RETURN jsonb_build_object('status','busy_or_pending_approval');
 END IF;
 IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,auto_last_status='paused_running_job' WHERE id=true;
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'paused_running_job'); RETURN jsonb_build_object('status','paused_running_job');
 END IF;
 -- Any previous production failure/partial result during the current armed period disables unattended execution.
 IF EXISTS(SELECT 1 FROM public.job_runs j WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
    AND j.status IN ('failed','partial') AND j.started_at>=c.auto_started_at) THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,
     auto_last_status='paused_after_failure' WHERE id=true;
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'paused_after_failure'); RETURN jsonb_build_object('status','paused_after_failure');
 END IF;
 -- The DB-level existing claim also enforces the limit. Guard before creating an approval.
 budget_status:=public.cogcor_daemon_budget_status_v1();
 IF budget_status<>'ready' THEN INSERT INTO cogcor_learning_private.audit(event_type,status) VALUES('reservation_status',budget_status); RETURN jsonb_build_object('status',budget_status); END IF;
 -- Candidates remain pending for review; no numeric backlog-based block.
 SELECT m.id INTO event_id
 FROM cogcor_chat_bridge.moments m
 WHERE m.origin='chatgpt_yuna_normal'
   AND m.recorded_at>=c.auto_started_at
   AND m.recorded_at<=now()-interval '2 minutes'
   AND m.memory_kind IN ('conversation_event','learned_rule','open_thread')
   AND m.evidence_type IN ('user_direct','observed_result')
   AND char_length(m.memory_content) BETWEEN 20 AND 1200
   AND char_length(btrim(coalesce(m.source_quote,''))) BETWEEN 5 AND 500
   AND NOT EXISTS (
     SELECT 1 FROM cogcor_daemon_private.queue q
     WHERE q.namespace='production' AND q.moment_id=m.id
   )
 ORDER BY m.id LIMIT 1;
 IF event_id IS NULL THEN INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'no_eligible_new_event'); RETURN jsonb_build_object('status','no_eligible_new_event'); END IF;
 approval := gen_random_uuid();
 UPDATE cogcor_daemon_private.control SET
   enabled=true,
   inference_approved=true,
   manual_approval_id=approval,
   manual_moment_id=event_id,
   manual_approval_expires_at=now()+interval '4 minutes',
   auto_approval_id=approval,
   auto_moment_id=event_id,
   auto_reserved_at=now(),
   auto_execution_deadline_at=NULL,
   auto_last_status='reserved'
 WHERE id=true;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'approved'); RETURN jsonb_build_object('status','approved','approval_id',approval);
END;
$function$;

UPDATE cogcor_daemon_private.control
 SET total_cost_cap_usd=3.00,
     cost_per_call_ceiling_usd=0.001,
     max_cost_usd_24h=3.00,
     max_calls_hour=12,
     max_calls_24h=48,
     pending_candidate_limit=20,
     budget_approved_until=NULL,
     auto_last_status='armed_cumulative_usd3'
 WHERE id=true AND namespace='production' AND auto_enabled=true;

DO $check$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE id AND total_cost_cap_usd=3.00 AND cost_per_call_ceiling_usd=0.001 AND auto_enabled=true)
 THEN RAISE EXCEPTION 'Budget policy did not update expected control'; END IF;
END $check$;
