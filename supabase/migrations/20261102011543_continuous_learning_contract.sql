-- NOT APPLIED. Requires Shinta approval and a fresh production snapshot.
BEGIN;
SET LOCAL lock_timeout='3s';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE enabled OR manual_approval_id IS NOT NULL OR auto_approval_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN RAISE EXCEPTION 'Quiesce and inspect live reservations before migration'; END IF;
END $$;
-- Explicitly pause during an approved cutover; never restore an armed state automatically.
UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false WHERE id;
CREATE SCHEMA cogcor_learning_private;
REVOKE ALL ON SCHEMA cogcor_learning_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA cogcor_learning_private TO service_role;
ALTER TABLE cogcor_daemon_private.control
 ADD COLUMN max_calls_hour integer NOT NULL DEFAULT 1 CHECK(max_calls_hour BETWEEN 1 AND 12),
 ADD COLUMN max_calls_24h integer NOT NULL DEFAULT 1 CHECK(max_calls_24h BETWEEN 1 AND 48),
 ADD COLUMN max_cost_usd_24h numeric NOT NULL DEFAULT 0 CHECK(max_cost_usd_24h>=0),
 ADD COLUMN cost_per_call_ceiling_usd numeric NOT NULL DEFAULT 0 CHECK(cost_per_call_ceiling_usd>=0),
 ADD COLUMN budget_approved_until timestamptz,
 ADD COLUMN pending_candidate_limit integer NOT NULL DEFAULT 5 CHECK(pending_candidate_limit BETWEEN 1 AND 20),
 ADD COLUMN auto_execution_deadline_at timestamptz;
CREATE TABLE cogcor_learning_private.call_reservations(
 run_id uuid PRIMARY KEY REFERENCES public.job_runs(id),event_id bigint UNIQUE NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 approval_id uuid UNIQUE NOT NULL,cost_ceiling_usd numeric NOT NULL CHECK(cost_ceiling_usd>0),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cogcor_learning_private.audit(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),event_type text NOT NULL CHECK(event_type IN ('cron_triggered','reservation_status','job_started','job_finished','inference_completed','inference_failed','candidate_created','skill_adopted','skill_retrieved','skill_selected','skill_applied','outcome_observed','outcome_scored','finalize_status','failure_reason')),
 event_id bigint,run_id uuid,ref_id uuid,status text NOT NULL CHECK(length(status)<=80),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cogcor_learning_private.cron_ticks(tick timestamptz PRIMARY KEY,created_at timestamptz NOT NULL DEFAULT now());
CREATE FUNCTION public.cogcor_daemon_budget_status_v1() RETURNS text
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE c cogcor_daemon_private.control; calls_hour integer; calls_day integer; cost numeric;
BEGIN
 SELECT * INTO STRICT c FROM cogcor_daemon_private.control WHERE id;
 IF c.budget_approved_until IS NULL OR c.budget_approved_until<=now() OR c.cost_per_call_ceiling_usd<=0 OR c.max_cost_usd_24h<c.cost_per_call_ceiling_usd THEN RETURN 'budget_unapproved'; END IF;
 SELECT count(*) FILTER(WHERE j.started_at>now()-interval '1 hour'),count(*),
 coalesce(sum(coalesce(r.cost_ceiling_usd,c.cost_per_call_ceiling_usd)),0) INTO calls_hour,calls_day,cost
 FROM public.job_runs j LEFT JOIN cogcor_learning_private.call_reservations r ON r.run_id=j.id
 WHERE j.job_name='cogcor_pseudo_daemon_v1:production' AND j.started_at>now()-interval '24 hours';
 IF calls_hour>=c.max_calls_hour OR calls_day>=c.max_calls_24h THEN RETURN 'call_budget'; END IF;
 IF cost+c.cost_per_call_ceiling_usd>c.max_cost_usd_24h THEN RETURN 'cost_budget'; END IF;
 RETURN 'ready';
END $$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_claim_v1(p_tick timestamp with time zone, p_test_only boolean DEFAULT false, p_approval_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE c cogcor_daemon_private.control; q cogcor_daemon_private.queue; r uuid; m jsonb; n integer; slot timestamptz; budget_status text;
BEGIN
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Missing control row'; END IF;
 IF p_tick IS NOT NULL AND abs(extract(epoch FROM now()-p_tick))>600 THEN RETURN jsonb_build_object('status','invalid_tick'); END IF;
 IF p_tick IS NULL OR p_test_only IS NULL THEN RAISE EXCEPTION 'Missing execution mode'; END IF;
 IF p_test_only AND (c.namespace<>'test' OR c.inference_approved) THEN RETURN jsonb_build_object('status','test_only_required'); END IF;
 IF NOT p_test_only AND c.namespace='test' THEN RETURN jsonb_build_object('status','production_required'); END IF;
 IF NOT c.enabled THEN RETURN jsonb_build_object('status','disabled'); END IF;
 IF c.namespace='production' AND NOT c.inference_approved THEN RETURN jsonb_build_object('status','approval_required'); END IF;
 IF c.namespace='production' AND (p_approval_id IS NULL OR c.manual_approval_id IS DISTINCT FROM p_approval_id OR c.manual_moment_id IS NULL OR c.manual_approval_expires_at IS NULL OR c.manual_approval_expires_at<=now()) THEN RETURN jsonb_build_object('status','approval_required'); END IF;
 IF c.namespace='production' THEN
  budget_status:=public.cogcor_daemon_budget_status_v1();
  IF budget_status<>'ready' THEN RETURN jsonb_build_object('status',budget_status); END IF;
  IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false,auto_last_status='paused_running_job' WHERE id;
   RETURN jsonb_build_object('status','paused_running_job');
  END IF;
 END IF;
 -- DB-level lease prevents overlap across Worker instances/redeployments.
 IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND status='running' AND started_at>now()-interval '10 minutes') THEN
  RETURN jsonb_build_object('status','busy');
 END IF;
 UPDATE cogcor_daemon_private.queue SET status='needs_review' WHERE status='running' AND namespace=c.namespace;
 UPDATE public.job_runs SET status='partial',error_summary='Lease expired; inspect receipts before retry',finished_at=now()
 WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND status='running';
 SELECT count(*) INTO n FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND started_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 IF c.namespace='test' AND n>=c.daily_limit THEN RETURN jsonb_build_object('status','daily_limit'); END IF;
 slot:=date_trunc('minute',p_tick);
 INSERT INTO public.job_runs(job_name,scheduled_for,trigger_source,input_summary)
 VALUES('cogcor_pseudo_daemon_v1:'||c.namespace,slot,CASE WHEN p_test_only THEN 'manual_test' WHEN c.auto_approval_id=p_approval_id THEN 'automatic_approved' ELSE 'manual_approved' END,jsonb_build_object('test_only',c.namespace='test','max_events',1))
 ON CONFLICT DO NOTHING RETURNING id INTO r;
 IF r IS NULL THEN RETURN jsonb_build_object('status','duplicate_tick'); END IF;
 INSERT INTO cogcor_daemon_private.queue(namespace,moment_id)
 SELECT c.namespace,mom.id FROM (SELECT id,evidence_type,memory_kind FROM cogcor_daemon_test.moments WHERE c.namespace='test' AND origin='cogcor_daemon_test_v1' UNION ALL SELECT id,evidence_type,memory_kind FROM cogcor_chat_bridge.moments WHERE c.namespace='production' AND origin='chatgpt_yuna_normal' AND id=c.manual_moment_id AND nullif(btrim(source_quote),'') IS NOT NULL) mom
 WHERE true
 AND mom.evidence_type IN ('user_direct','observed_result')
 AND mom.memory_kind IN ('conversation_event','learned_rule','open_thread')
 AND NOT EXISTS(SELECT 1 FROM cogcor_daemon_private.queue existing WHERE existing.namespace=c.namespace AND existing.moment_id=mom.id)
 ORDER BY mom.id LIMIT 100 ON CONFLICT DO NOTHING;
 SELECT * INTO q FROM cogcor_daemon_private.queue WHERE namespace=c.namespace AND (c.namespace='test' OR moment_id=c.manual_moment_id) AND status='pending' AND attempts<3 AND available_at<=now() ORDER BY moment_id LIMIT 1 FOR UPDATE SKIP LOCKED;
 IF NOT FOUND THEN
  UPDATE public.job_runs SET status='skipped',finished_at=now(),output_summary='{"reason":"no_unprocessed_event"}' WHERE id=r;
  RETURN jsonb_build_object('status','no_unprocessed_event','run_id',r);
 END IF;
 -- Manual authorization is consumed atomically; further requests cannot run another event.
 IF p_test_only OR c.namespace='production' THEN UPDATE cogcor_daemon_private.control SET enabled=false,manual_approval_id=NULL,manual_moment_id=NULL,manual_approval_expires_at=NULL WHERE id; END IF;
 IF c.namespace='production' THEN
  INSERT INTO cogcor_learning_private.call_reservations(run_id,event_id,approval_id,cost_ceiling_usd)
  VALUES(r,q.moment_id,p_approval_id,c.cost_per_call_ceiling_usd);
  IF c.auto_approval_id=p_approval_id THEN UPDATE cogcor_daemon_private.control SET auto_execution_deadline_at=now()+interval '10 minutes' WHERE id; END IF;
 END IF;
 UPDATE cogcor_daemon_private.queue SET status='running',attempts=attempts+1,run_id=r WHERE namespace=q.namespace AND moment_id=q.moment_id;
 IF c.namespace='test' THEN
  SELECT to_jsonb(mom)||jsonb_build_object('source_table','cogcor_daemon_test.moments') INTO m FROM cogcor_daemon_test.moments mom WHERE id=q.moment_id;
 ELSE
  SELECT to_jsonb(mom)||jsonb_build_object('source_table','cogcor_chat_bridge.moments') INTO m FROM cogcor_chat_bridge.moments mom WHERE id=q.moment_id;
 END IF;
 UPDATE public.job_runs SET input_summary=jsonb_build_object('test_only',c.namespace='test','moment_id',q.moment_id,'model_calls_reserved',CASE WHEN c.namespace='production' THEN 1 ELSE 0 END) WHERE id=r;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(r,'claim','completed',1,1,jsonb_build_object('source_records',jsonb_build_array(jsonb_build_object('table',CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test.moments' ELSE 'cogcor_chat_bridge.moments' END,'id',q.moment_id::text,'role','supporting')),'test_only',c.namespace='test'),now());
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,run_id,status) VALUES('job_started',q.moment_id,r,'running');
 RETURN jsonb_build_object('status','claimed','namespace',c.namespace,'run_id',r,'event',m,'inference_approved',c.inference_approved);
END; $function$;

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
 -- Do not pile up unreviewed hypotheses indefinitely.
 IF (SELECT count(*) FROM public.cognitive_proposals p
      JOIN public.job_runs j ON j.id=p.job_run_id
      WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
        AND p.status='pending' AND p.rationale LIKE '%learning_candidate%')>=c.pending_candidate_limit THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,
      auto_last_status='paused_candidate_backlog' WHERE id=true;
   INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('reservation_status',event_id,'paused_candidate_backlog'); RETURN jsonb_build_object('status','paused_candidate_backlog');
 END IF;
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

CREATE OR REPLACE FUNCTION public.cogcor_daemon_auto_finalize_v1(p_approval_id uuid, p_success boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
 c cogcor_daemon_private.control;
 verified boolean;
BEGIN
 IF p_approval_id IS NULL OR p_success IS NULL THEN RAISE EXCEPTION 'bad_finalize'; END IF;
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id=true FOR UPDATE;
 IF NOT FOUND OR c.auto_approval_id IS DISTINCT FROM p_approval_id THEN
    RETURN jsonb_build_object('status','approval_mismatch');
 END IF;
 SELECT EXISTS(SELECT 1 FROM public.job_runs j
     JOIN cogcor_daemon_private.queue q ON q.run_id=j.id
     WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
     AND j.status='completed'
     AND j.trigger_source='automatic_approved'
     AND j.started_at>=c.auto_reserved_at AND j.started_at<=c.auto_reserved_at+interval '4 minutes'
     AND j.finished_at<=c.auto_execution_deadline_at
     AND q.namespace='production' AND q.moment_id=c.auto_moment_id AND q.status='completed'
     AND j.input_summary->>'moment_id'=c.auto_moment_id::text
     AND EXISTS(SELECT 1 FROM public.job_stages s WHERE s.job_run_id=j.id AND s.stage_name='inference'
                AND s.status='completed' AND s.receipt->>'validation'='accepted')
     AND EXISTS(SELECT 1 FROM public.cognitive_proposals p WHERE p.job_run_id=j.id
                AND p.status='pending' AND p.rationale LIKE '%learning_candidate%'
                AND p.source_records @> jsonb_build_array(jsonb_build_object('table','cogcor_chat_bridge.moments','id',c.auto_moment_id::text)))) INTO verified;
 UPDATE cogcor_daemon_private.control SET
   enabled=false,
   inference_approved=false,
   manual_approval_id=NULL,
   manual_moment_id=NULL,
   manual_approval_expires_at=NULL,
   auto_approval_id=NULL,
   auto_moment_id=NULL,
   auto_reserved_at=NULL,
   auto_execution_deadline_at=NULL,
   auto_enabled=CASE WHEN p_success AND verified THEN auto_enabled ELSE false END,
   auto_last_status=CASE WHEN p_success AND verified THEN 'completed'
                         ELSE 'paused_after_run' END
 WHERE id=true;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('finalize_status',c.auto_moment_id,CASE WHEN p_success AND verified THEN 'completed' ELSE 'disarmed' END);
 RETURN jsonb_build_object('status',CASE WHEN p_success AND verified
                                        THEN 'completed' ELSE 'disarmed' END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_finish_v1(p_run uuid, p_status text, p_error text, p_retry_safe boolean)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF p_status NOT IN ('completed','failed') THEN RAISE EXCEPTION 'Invalid finish'; END IF;
 UPDATE cogcor_daemon_private.queue SET status=CASE WHEN p_status='completed' THEN 'completed' WHEN namespace='test' AND p_retry_safe AND attempts<3 THEN 'pending' ELSE 'needs_review' END,
 available_at=now()+make_interval(mins=>30*attempts)
 WHERE run_id=p_run AND status='running';
 IF NOT FOUND THEN RAISE EXCEPTION 'No matching running claim'; END IF;
 UPDATE public.job_stages SET status='failed',error_summary=left(p_error,150),finished_at=now() WHERE job_run_id=p_run AND status='running';
 UPDATE public.job_runs SET status=CASE WHEN p_status='failed' AND EXISTS(SELECT 1 FROM public.job_stages WHERE job_run_id=p_run AND stage_name IN ('reflection','metacognition') AND status='completed') THEN 'partial' ELSE p_status END,
 error_summary=left(p_error,150),finished_at=now(),output_summary=jsonb_build_object('native_completed_stages',(SELECT count(*) FROM public.job_stages WHERE job_run_id=p_run AND status='completed'),'outcome_observed',false)
 WHERE id=p_run AND status='running';
 IF p_status='failed' AND EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name='cogcor_pseudo_daemon_v1:production') THEN
 UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false,auto_last_status='paused_after_failure' WHERE id;
 END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('job_finished',p_run,p_status);
 IF p_status='failed' THEN INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('failure_reason',p_run,CASE WHEN p_error ~ '^AI_(OUTPUT_[A-Z_]+|BINDING_FAILED|TIMEOUT)$' THEN p_error ELSE 'EXECUTION_FAILED' END); END IF;
END; $function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_stage_v1(p_run uuid, p_stage text, p_status text, p_receipt jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF p_stage NOT IN ('context','self_model_review','reflection','metacognition','fixture_skill','fixture_self_hypothesis','inference')
 OR (p_status NOT IN ('running','completed') AND NOT (p_stage='inference' AND p_status='failed')) THEN RAISE EXCEPTION 'Invalid stage'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name LIKE 'cogcor_pseudo_daemon_v1:%' AND status='running' AND started_at>now()-interval '9 minutes') THEN RAISE EXCEPTION 'Run not running'; END IF;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,p_stage,p_status,1,CASE WHEN p_status='completed' THEN 1 ELSE 0 END,p_receipt,CASE WHEN p_status IN ('completed','failed') THEN now() END)
 ON CONFLICT(job_run_id,stage_name) DO UPDATE SET status=excluded.status,output_count=excluded.output_count,receipt=excluded.receipt,finished_at=excluded.finished_at;
IF p_stage='inference' AND p_status IN ('completed','failed') THEN INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES(CASE WHEN p_status='completed' THEN 'inference_completed' ELSE 'inference_failed' END,p_run,p_status); END IF;
END; $function$;
CREATE OR REPLACE FUNCTION public.cogcor_daemon_candidate_v1(p_run uuid, p_content text, p_question text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE q cogcor_daemon_private.queue; refs jsonb; target_schema text;
BEGIN
 SELECT * INTO STRICT q FROM cogcor_daemon_private.queue WHERE run_id=p_run AND status='running';
 IF length(p_content) NOT BETWEEN 1 AND 1200 OR length(p_question) NOT BETWEEN 1 AND 800 THEN RAISE EXCEPTION 'Candidate budget'; END IF;
 refs:=jsonb_build_array(jsonb_build_object('table',CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test.moments' ELSE 'cogcor_chat_bridge.moments' END,'id',q.moment_id::text,'role','supporting'));
 target_schema:=CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test' ELSE 'public' END;
 -- Existing orphan proposal class: a sourced memory/procedure requiring review.
 EXECUTE format('INSERT INTO %I.cognitive_proposals(proposal_type,proposed_content,rationale,confidence,source_records,job_run_id) VALUES(''orphan'',$1,$2,0.3,$3,$4)',target_schema)
 USING p_content,jsonb_build_object('kind','learning_candidate','self_model_question',p_question,'interpretation_status','unreviewed','test_only',q.namespace='test')::text,refs,p_run;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,'candidate','completed',1,1,jsonb_build_object('source_records',refs,'review_required',true,'test_only',q.namespace='test'),now());
INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('candidate_created',p_run,'pending');
END; $function$;
-- Reviewed procedure and observed application lifecycle.
CREATE TABLE cogcor_learning_private.reviews (
 candidate_id uuid PRIMARY KEY REFERENCES public.cognitive_proposals(id),
 source_event_id bigint NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 review_event_id bigint NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 skill_id uuid UNIQUE REFERENCES public.skills(id),
 state text NOT NULL CHECK(state IN ('approved','held','rejected','disabled')),
 conditions text NOT NULL CHECK(length(btrim(conditions)) BETWEEN 5 AND 1000),
 expected_improvement text NOT NULL CHECK(length(btrim(expected_improvement)) BETWEEN 5 AND 1000),
 comparison_notes text NOT NULL CHECK(length(btrim(comparison_notes)) BETWEEN 10 AND 2000),
 compared_skill_ids uuid[] NOT NULL,
 reviewed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cogcor_learning_private.applications (
 id uuid PRIMARY KEY,
 candidate_id uuid NOT NULL REFERENCES cogcor_learning_private.reviews(candidate_id),
 skill_id uuid NOT NULL REFERENCES public.skills(id),
 conversation_ref text NOT NULL CHECK(length(conversation_ref) BETWEEN 1 AND 120),
 stage text NOT NULL DEFAULT 'retrieved' CHECK(stage IN ('retrieved','selected','applied','outcome_observed','scored')),
 applicability text CHECK(length(applicability)<=1000),
 decision_ref text CHECK(length(decision_ref)<=120),
 retrieved_at timestamptz NOT NULL DEFAULT now(),selected_at timestamptz,applied_at timestamptz,
 observation_id bigint REFERENCES cogcor_chat_bridge.moments(id),observed_at timestamptz,
 outcome_id uuid UNIQUE REFERENCES public.outcome_scores(id),scored_at timestamptz,
 UNIQUE(skill_id,conversation_ref),UNIQUE(candidate_id,observation_id)
);

-- Unicode normalization is lexical, not semantic inference. Do not infer evidence from similarity.
CREATE FUNCTION cogcor_learning_private.normalized(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT translate(lower(normalize(coalesce(p_text,''),NFKC)),
 'ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴ',
 'ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをんゔ')
$$;
CREATE FUNCTION cogcor_learning_private.rank_text(p_query text,p_text text) RETURNS real
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 WITH t AS(SELECT cogcor_learning_private.normalized(p_query) q,cogcor_learning_private.normalized(p_text) d),
 words AS(SELECT w FROM t,regexp_split_to_table(q,'[[:space:]、。？！?!]+') w WHERE length(w)>=2 AND w NOT IN ('について','教えて','ください','前に','のこと'))
 SELECT CASE WHEN length(q)<2 THEN 0 ELSE greatest(
 CASE WHEN strpos(d,q)>0 THEN 1.0 ELSE 0 END,
 coalesce((SELECT count(*) FILTER(WHERE strpos(d,w)>0)::real/nullif(count(*),0) FROM words)*0.8,0),
 extensions.word_similarity(q,d)*0.65) END::real FROM t
$$;

-- Human/operator review only, deliberately NOT executable by the Worker service role.
CREATE FUNCTION public.cogcor_learning_review_v1(p_candidate uuid,p_review_event bigint,p_decision text,p_conditions text,p_expected text,p_comparison_notes text,p_compared_skills uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE p public.cognitive_proposals; m cogcor_chat_bridge.moments; s uuid; existing cogcor_learning_private.reviews;
BEGIN
 IF p_decision IS NULL OR p_decision NOT IN ('approved','held','rejected','disabled') THEN RAISE EXCEPTION 'review_decision'; END IF;
 PERFORM pg_advisory_xact_lock(31020261); -- serializes adoption/duplicate checks
 SELECT * INTO STRICT p FROM public.cognitive_proposals WHERE id=p_candidate FOR UPDATE;
 IF p.proposal_type<>'orphan' OR p.rationale NOT LIKE '%learning_candidate%' OR NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p.job_run_id AND job_name='cogcor_pseudo_daemon_v1:production' AND status='completed') THEN RAISE EXCEPTION 'not_completed_candidate'; END IF;
 SELECT * INTO m FROM cogcor_chat_bridge.moments WHERE id=(p.source_records->0->>'id')::bigint
 AND p.source_records->0->>'table'='cogcor_chat_bridge.moments';
 IF NOT FOUND OR m.origin<>'chatgpt_yuna_normal' OR m.evidence_type NOT IN ('user_direct','observed_result') OR nullif(btrim(m.source_quote),'') IS NULL THEN RAISE EXCEPTION 'candidate_evidence'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cogcor_chat_bridge.moments WHERE id=p_review_event AND origin='chatgpt_yuna_normal' AND evidence_type='user_direct' AND nullif(btrim(source_quote),'') IS NOT NULL AND recorded_at>=p.created_at) THEN RAISE EXCEPTION 'review_requires_later_direct_statement'; END IF;
 IF p_compared_skills IS NULL OR EXISTS(SELECT 1 FROM public.skills WHERE status='active' AND NOT(id=ANY(p_compared_skills))) THEN RAISE EXCEPTION 'compare_all_active_skills'; END IF;
 SELECT * INTO existing FROM cogcor_learning_private.reviews WHERE candidate_id=p_candidate;
 IF FOUND AND existing.state='rejected' THEN RAISE EXCEPTION 'rejected_candidate_requires_new_review_candidate'; END IF;
 s:=existing.skill_id;
 IF p_decision='approved' AND s IS NULL THEN
  IF EXISTS(SELECT 1 FROM public.skills WHERE status='active' AND cogcor_learning_private.normalized(approach)=cogcor_learning_private.normalized(p.proposed_content)) THEN RAISE EXCEPTION 'duplicate_skill'; END IF;
  INSERT INTO public.skills(skill_name,description,approach,trigger_context,source,tags)
  VALUES('Reviewed procedure '||left(p.id::text,8),p_expected,p.proposed_content,p_conditions,'cogcor_reviewed_candidate','["reviewed_procedure"]') RETURNING id INTO s;
 END IF;
 INSERT INTO cogcor_learning_private.reviews(candidate_id,source_event_id,review_event_id,skill_id,state,conditions,expected_improvement,comparison_notes,compared_skill_ids)
 VALUES(p.id,m.id,p_review_event,s,p_decision,p_conditions,p_expected,p_comparison_notes,p_compared_skills)
 ON CONFLICT(candidate_id) DO UPDATE SET skill_id=excluded.skill_id,review_event_id=excluded.review_event_id,state=excluded.state,conditions=excluded.conditions,expected_improvement=excluded.expected_improvement,comparison_notes=excluded.comparison_notes,compared_skill_ids=excluded.compared_skill_ids,reviewed_at=now();
 IF p_decision='approved' THEN
  UPDATE public.cognitive_proposals SET status='accepted',accepted_record_table='skills',accepted_record_id=s,resolved_at=now() WHERE id=p.id;
 ELSIF p_decision='rejected' THEN UPDATE public.cognitive_proposals SET status='rejected',resolved_at=now() WHERE id=p.id; END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) VALUES('skill_adopted',m.id,s,p_decision);
 RETURN jsonb_build_object('review_status',p_decision,'skill_id',s,'effectiveness_verified',false);
END $$;

CREATE FUNCTION public.cogcor_learning_context_v1(p_query text,p_limit integer DEFAULT 5)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('reviewed_skills',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
  SELECT s.id AS skill_id,r.candidate_id,s.skill_name,s.approach,r.conditions,r.expected_improvement,
   r.source_event_id,r.review_event_id,m.evidence_type,m.source_quote,'reviewed_procedure_not_user_fact' AS evidence_class,
   s.times_used,s.times_succeeded,s.times_failed,
   cogcor_learning_private.rank_text(p_query,s.skill_name||' '||s.approach||' '||r.conditions) AS relevance
  FROM cogcor_learning_private.reviews r JOIN public.skills s ON s.id=r.skill_id JOIN cogcor_chat_bridge.moments m ON m.id=r.source_event_id
  WHERE r.state='approved' AND s.status='active' AND length(p_query) BETWEEN 2 AND 300
   AND cogcor_learning_private.rank_text(p_query,s.skill_name||' '||s.approach||' '||r.conditions)>=0.3
  ORDER BY relevance DESC,s.id LIMIT greatest(1,least(coalesce(p_limit,5),10)))x),'[]'::jsonb),
  'unreviewed_candidates',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (
   SELECT p.id AS candidate_id,p.proposed_content,p.source_records,'unreviewed_hypothesis' AS evidence_class
   FROM public.cognitive_proposals p JOIN public.job_runs j ON j.id=p.job_run_id
   WHERE p.status='pending' AND p.proposal_type='orphan' AND j.status='completed' AND j.job_name='cogcor_pseudo_daemon_v1:production'
   AND cogcor_learning_private.rank_text(p_query,p.proposed_content)>=0.3 ORDER BY p.created_at DESC LIMIT 3)x),'[]'::jsonb),
  'retrieval_is_application',false)
$$;

CREATE FUNCTION public.cogcor_learning_application_v1(p_id uuid,p_skill uuid,p_conversation_ref text,p_stage text,p_evidence text DEFAULT NULL,p_observation bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE a cogcor_learning_private.applications; r cogcor_learning_private.reviews; m cogcor_chat_bridge.moments;
BEGIN
 SELECT * INTO r FROM cogcor_learning_private.reviews WHERE skill_id=p_skill AND state='approved' FOR SHARE;
 IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.skills WHERE id=p_skill AND status='active') THEN RAISE EXCEPTION 'skill_not_reviewed_active'; END IF;
 IF p_id IS NULL OR p_stage IS NULL OR p_stage NOT IN ('retrieved','selected','applied','outcome_observed') THEN RAISE EXCEPTION 'invalid_stage'; END IF;
 IF p_stage='retrieved' THEN
  INSERT INTO cogcor_learning_private.applications(id,candidate_id,skill_id,conversation_ref) VALUES(p_id,r.candidate_id,p_skill,p_conversation_ref) ON CONFLICT DO NOTHING;
  IF FOUND THEN INSERT INTO cogcor_learning_private.audit(event_type,ref_id,status) VALUES('skill_retrieved',p_id,'retrieved'); END IF;
 END IF;
 SELECT * INTO a FROM cogcor_learning_private.applications WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR a.skill_id<>p_skill OR a.conversation_ref IS DISTINCT FROM p_conversation_ref THEN RAISE EXCEPTION 'application_identity'; END IF;
 IF a.stage=p_stage THEN
  IF (p_stage='selected' AND a.applicability IS DISTINCT FROM p_evidence) OR (p_stage='applied' AND a.decision_ref IS DISTINCT FROM p_evidence) OR (p_stage='outcome_observed' AND a.observation_id IS DISTINCT FROM p_observation) THEN RAISE EXCEPTION 'conflicting_replay'; END IF;
  RETURN jsonb_build_object('application_id',a.id,'stage',a.stage,'changed',false);
 END IF;
 IF p_stage='selected' AND a.stage='retrieved' AND length(btrim(p_evidence)) BETWEEN 5 AND 1000 THEN
  UPDATE cogcor_learning_private.applications SET stage=p_stage,applicability=p_evidence,selected_at=now() WHERE id=a.id;
 ELSIF p_stage='applied' AND a.stage='selected' AND length(btrim(p_evidence)) BETWEEN 1 AND 120 THEN
  UPDATE cogcor_learning_private.applications SET stage=p_stage,decision_ref=p_evidence,applied_at=now() WHERE id=a.id;
  UPDATE public.skills SET times_used=coalesce(times_used,0)+1,last_used_at=now(),updated_at=now() WHERE id=p_skill;
 ELSIF p_stage='outcome_observed' AND a.stage='applied' THEN
  SELECT * INTO m FROM cogcor_chat_bridge.moments WHERE id=p_observation;
  IF NOT FOUND OR m.origin<>'chatgpt_yuna_normal' OR m.evidence_type NOT IN ('user_direct','observed_result') OR nullif(btrim(m.source_quote),'') IS NULL OR m.recorded_at<a.applied_at THEN RAISE EXCEPTION 'later_sourced_observation_required'; END IF;
  UPDATE cogcor_learning_private.applications SET stage=p_stage,observation_id=m.id,observed_at=m.recorded_at WHERE id=a.id;
 ELSE RAISE EXCEPTION 'invalid_transition'; END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) VALUES(CASE p_stage WHEN 'selected' THEN 'skill_selected' WHEN 'applied' THEN 'skill_applied' ELSE 'outcome_observed' END,p_observation,a.id,p_stage);
 RETURN jsonb_build_object('application_id',a.id,'stage',p_stage,'changed',true,'application_evidence','agent_reported_until_observed');
END $$;

-- Explicit human/operator scoring; generic score_outcome cannot bypass this contract.
CREATE FUNCTION public.cogcor_learning_score_v1(p_application uuid,p_helped boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE a cogcor_learning_private.applications; o record;
BEGIN
 IF p_helped IS NULL THEN RAISE EXCEPTION 'observed_result_required'; END IF;
 SELECT * INTO STRICT a FROM cogcor_learning_private.applications WHERE id=p_application;
 -- Same lock order as application: review -> application -> skill.
 PERFORM 1 FROM cogcor_learning_private.reviews WHERE candidate_id=a.candidate_id FOR UPDATE;
 SELECT * INTO STRICT a FROM cogcor_learning_private.applications WHERE id=p_application FOR UPDATE;
 IF a.stage='scored' THEN
  IF NOT EXISTS(SELECT 1 FROM public.outcome_scores WHERE id=a.outcome_id AND score=CASE WHEN p_helped THEN 1 ELSE -1 END) THEN RAISE EXCEPTION 'conflicting_score'; END IF;
  RETURN jsonb_build_object('stage','scored','outcome_id',a.outcome_id,'changed',false);
 END IF;
 IF a.stage<>'outcome_observed' THEN RAISE EXCEPTION 'observation_before_score'; END IF;
 SELECT * INTO o FROM cogcor_chat_bridge.record_learning_outcome(a.candidate_id,a.observation_id,p_helped);
 IF NOT o.saved THEN RAISE EXCEPTION 'observation_already_scored'; END IF;
 UPDATE public.skills SET times_succeeded=coalesce(times_succeeded,0)+CASE WHEN p_helped THEN 1 ELSE 0 END,
 times_failed=coalesce(times_failed,0)+CASE WHEN p_helped THEN 0 ELSE 1 END,
 effectiveness=(coalesce(times_succeeded,0)+CASE WHEN p_helped THEN 1 ELSE 0 END)::real/(coalesce(times_succeeded,0)+coalesce(times_failed,0)+1),updated_at=now() WHERE id=a.skill_id;
 UPDATE cogcor_learning_private.applications SET stage='scored',outcome_id=o.outcome_id,scored_at=now() WHERE id=a.id;
 -- A negative result pauses this procedure for review, without erasing the skill or history.
 IF NOT p_helped THEN UPDATE cogcor_learning_private.reviews SET state='held' WHERE candidate_id=a.candidate_id; END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) VALUES('outcome_scored',a.observation_id,a.id,CASE WHEN p_helped THEN 'positive' ELSE 'negative' END);
 RETURN jsonb_build_object('stage','scored','outcome_id',o.outcome_id,'changed',true);
END $$;
CREATE FUNCTION public.cogcor_learning_search_v1(p_query text,p_limit integer DEFAULT 8,p_person text DEFAULT NULL,p_after timestamptz DEFAULT NULL,p_before timestamptz DEFAULT NULL,p_origin text DEFAULT NULL)
RETURNS TABLE(event_id bigint,content text,evidence_type text,source_quote text,source_ref text,recorded_at timestamptz,relevance real)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT m.id,m.memory_content,m.evidence_type,m.source_quote,'cogcor_chat_bridge:moments:'||m.id,m.recorded_at,
 cogcor_learning_private.rank_text(p_query,m.memory_content)
 FROM cogcor_chat_bridge.moments m
 WHERE length(p_query) BETWEEN 2 AND 300
 AND (p_person IS NULL OR strpos(cogcor_learning_private.normalized(m.memory_content),cogcor_learning_private.normalized(p_person))>0)
 AND (p_after IS NULL OR m.recorded_at>=p_after) AND (p_before IS NULL OR m.recorded_at<=p_before)
 AND (p_origin IS NULL OR m.origin=p_origin)
 AND cogcor_learning_private.rank_text(p_query,m.memory_content)>=0.3
 ORDER BY cogcor_learning_private.rank_text(p_query,m.memory_content) DESC,m.id LIMIT greatest(1,least(coalesce(p_limit,8),20))
$$;
CREATE OR REPLACE FUNCTION public.cogcor_daemon_related_outcomes_v1(p_query text, p_hours integer DEFAULT 24, p_limit integer DEFAULT 3)
 RETURNS TABLE(outcome_id uuid, candidate_id uuid, candidate text, score real, evidence_ref text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT o.id,p.id,left(p.proposed_content,450),o.score::real,o.notes
 FROM public.outcome_scores o
 JOIN public.cognitive_proposals p ON p.id=o.target_id
 JOIN public.job_runs j ON j.id=p.job_run_id
 JOIN cogcor_chat_bridge.moments m ON o.notes='cogcor_chat_bridge:moments:'||m.id::text
 WHERE EXISTS(SELECT 1 FROM cogcor_learning_private.applications a WHERE a.outcome_id=o.id AND a.stage='scored')
 AND cogcor_learning_private.rank_text(p_query,p.proposed_content)>=0.3
 AND o.target_type='cogcor_learning_candidate' AND o.source='chatgpt_yuna_normal'
 AND o.score IN (-1,1) AND j.job_name='cogcor_pseudo_daemon_v1:production' AND j.status='completed'
 AND p.status IN ('pending','accepted') AND p.proposal_type='orphan' AND p.rationale LIKE '%learning_candidate%'
 AND jsonb_array_length(p.source_records)>0
 AND m.origin='chatgpt_yuna_normal' AND m.evidence_type IN ('user_direct','observed_result')
 AND nullif(btrim(m.source_quote),'') IS NOT NULL AND m.recorded_at>=p.created_at AND o.created_at>=m.recorded_at
 AND o.created_at>=now()-make_interval(hours=>greatest(1,least(coalesce(p_hours,24),72)))
 ORDER BY o.created_at DESC,o.id LIMIT greatest(1,least(coalesce(p_limit,3),3));
$function$;

CREATE OR REPLACE FUNCTION cogcor_chat_bridge.recall(p_query text, p_limit integer DEFAULT 8)
 RETURNS TABLE(memory_kind text, memory_source text, memory_content text, relevance real)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
WITH input AS (
 SELECT lower(trim(left(coalesce(p_query,''),300))) AS q,
        greatest(1,least(coalesce(p_limit,8),20)) AS n
), documents AS (
 SELECT memory_kind::text AS kind,'cogcor_chat_bridge:moments:'||id::text AS src,
       ('【'||evidence_type||' / 登録日JST='||event_date::text||'（出来事の発生日ではない） / 出典原文照合=未検証】'||memory_content||
        CASE WHEN nullif(source_quote,'') IS NOT NULL THEN E'\n保存引用（原文一致・本文全体の裏付けは未検証）: '||source_quote ELSE '' END)::text AS body, memory_content::text AS searchable
 FROM cogcor_chat_bridge.moments WHERE memory_kind IN ('conversation_event','user_fact','assistant_reflection','learned_rule','open_thread')
 UNION ALL
 SELECT 'creative_or_personal',coalesce(source,''),content,content FROM public.custom_memories WHERE status='active'
 UNION ALL
 SELECT 'learning_candidate_unreviewed'::text,
        'cogcor_daemon:proposal:'||p.id::text,
        ('【AIの未承認学習候補。ユーザーの事実・確定人格ではない。使用後の観測で評価すること】'
         || E'\n候補: '||p.proposed_content
         || E'\n審査状態: '||p.status
         || E'\n出典: '||p.source_records::text),
        concat_ws(' ',p.proposed_content,coalesce(m.memory_content,''))
 FROM public.cognitive_proposals p
 JOIN public.job_runs j ON j.id=p.job_run_id AND j.job_name='cogcor_pseudo_daemon_v1:production' AND j.status='completed'
 LEFT JOIN cogcor_chat_bridge.moments m ON (p.source_records->0->>'table')='cogcor_chat_bridge.moments' AND (p.source_records->0->>'id')=m.id::text
 WHERE p.status IN ('pending','accepted') AND p.proposal_type='orphan'
   AND p.rationale LIKE '%learning_candidate%'
 UNION ALL
 SELECT 'inside_joke',coalesce(source,''),content,content FROM public.inside_jokes WHERE status='active'
 UNION ALL
 SELECT 'pattern',coalesce(source,''),concat_ws(E'\n',description,content),concat_ws(E'\n',description,content) FROM public.patterns WHERE status='active'
 UNION ALL
 SELECT CASE WHEN r.state='approved' THEN 'reviewed_procedure' ELSE 'legacy_skill_unreviewed' END,
 coalesce(s.source,''),concat_ws(E'\n',CASE WHEN r.state='approved' THEN '【審査済み手順。本人事実ではなく、実効性は結果観測で確認】' ELSE '【旧登録スキル。審査・実効性は未確認】' END,s.skill_name,s.description,s.trigger_context,s.approach),
 concat_ws(E'\n',s.skill_name,s.description,s.trigger_context,s.approach)
 FROM public.skills s LEFT JOIN cogcor_learning_private.reviews r ON r.skill_id=s.id
 WHERE s.status='active' AND (r.state IS NULL OR r.state='approved')
 UNION ALL
 SELECT 'essence',coalesce(source,''),content,content FROM public.essence WHERE pinned IS TRUE
 UNION ALL
 SELECT 'person',coalesce(source,''),concat_ws(E'\n',name,content),concat_ws(E'\n',name,content) FROM public.people
), scored AS (
 SELECT d.kind,d.src,d.body,greatest(
  CASE WHEN position(i.q in lower(d.searchable))>0 THEN 1.0 ELSE 0.0 END,
  extensions.word_similarity(i.q,lower(d.searchable)),
  cogcor_learning_private.rank_text(i.q,d.searchable),
  extensions.similarity(i.q,lower(d.searchable))
 )::real score
 FROM documents d CROSS JOIN input i WHERE char_length(i.q)>=2
 AND (CASE
 WHEN i.q ~ '[[:space:]　]' THEN cogcor_learning_private.rank_text(i.q,d.searchable)>=0.3
 WHEN char_length(i.q)<=4 AND i.q ~ '[ぁ-んァ-ヶ一-龠]' THEN position(i.q in lower(d.searchable))>0
 ELSE true END)
)
SELECT kind,src,body,score FROM scored WHERE score>=0.25
ORDER BY score DESC,CASE kind WHEN 'conversation_event' THEN 1 WHEN 'user_fact' THEN 1 WHEN 'learned_rule' THEN 1 WHEN 'assistant_reflection' THEN 1 WHEN 'open_thread' THEN 1 WHEN 'inside_joke' THEN 2 WHEN 'creative_or_personal' THEN 3
 WHEN 'pattern' THEN 4 WHEN 'skill' THEN 5 ELSE 6 END,src
LIMIT (SELECT n FROM input);
$function$;

-- Private schemas remain inaccessible to anon/authenticated. No existing RLS is changed.
ALTER TABLE cogcor_learning_private.call_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.cron_ticks ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.applications ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE ON cogcor_learning_private.call_reservations,cogcor_learning_private.cron_ticks,cogcor_learning_private.audit,cogcor_learning_private.applications TO service_role;
GRANT SELECT ON cogcor_learning_private.reviews TO service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cogcor_learning_private FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cogcor_learning_private TO service_role;
REVOKE ALL ON FUNCTION public.cogcor_learning_review_v1(uuid,bigint,text,text,text,text,uuid[]) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.cogcor_learning_score_v1(uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.cogcor_learning_context_v1(text,integer),public.cogcor_learning_application_v1(uuid,uuid,text,text,text,bigint),public.cogcor_learning_search_v1(text,integer,text,timestamptz,timestamptz,text),public.cogcor_daemon_budget_status_v1(),public.cogcor_daemon_related_outcomes_v1(text,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_learning_context_v1(text,integer),public.cogcor_learning_application_v1(uuid,uuid,text,text,text,bigint),public.cogcor_learning_search_v1(text,integer,text,timestamptz,timestamptz,text),public.cogcor_daemon_budget_status_v1(),public.cogcor_daemon_related_outcomes_v1(text,integer,integer) TO service_role;
COMMIT;
