BEGIN;
SET LOCAL lock_timeout='3s';
UPDATE cogcor_daemon_private.control SET auto_enabled=false WHERE id;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') OR EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE enabled OR inference_approved OR auto_approval_id IS NOT NULL OR manual_approval_id IS NOT NULL) THEN RAISE EXCEPTION 'Resolve active work before rollback'; END IF; END $$;
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
END; $function$
;
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
$function$
;
REVOKE EXECUTE ON FUNCTION public.cogcor_learning_capture_v1(text,text,timestamptz,text,text,text,text,text),public.cogcor_learning_provisional_context_v1(text,integer),public.cogcor_learning_correct_v1(uuid,bigint),public.cogcor_learning_provisional_apply_v1(uuid,uuid,text,text,text,bigint,text) FROM service_role;
COMMIT;
