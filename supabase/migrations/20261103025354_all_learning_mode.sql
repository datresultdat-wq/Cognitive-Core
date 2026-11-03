SET LOCAL lock_timeout='3s';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE auto_enabled OR enabled OR inference_approved OR auto_approval_id IS NOT NULL OR manual_approval_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN RAISE EXCEPTION 'Pause and resolve active work first'; END IF;
END $$;
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
   AND m.memory_kind IN ('conversation_event','user_fact','assistant_reflection','learned_rule','open_thread')
   AND m.evidence_type IN ('user_direct','observed_result','assistant_interpretation','conversation_summary')
   AND char_length(m.memory_content) BETWEEN 1 AND 1600
   AND (m.evidence_type<>'user_direct' OR nullif(btrim(m.source_quote),'') IS NOT NULL)
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
 SELECT c.namespace,mom.id FROM (SELECT id,evidence_type,memory_kind FROM cogcor_daemon_test.moments WHERE c.namespace='test' AND origin='cogcor_daemon_test_v1' UNION ALL SELECT id,evidence_type,memory_kind FROM cogcor_chat_bridge.moments WHERE c.namespace='production' AND origin='chatgpt_yuna_normal' AND id=c.manual_moment_id AND (evidence_type<>'user_direct' OR nullif(btrim(source_quote),'') IS NOT NULL)) mom
 WHERE true
 AND mom.evidence_type IN ('user_direct','observed_result','assistant_interpretation','conversation_summary')
 AND mom.memory_kind IN ('conversation_event','user_fact','assistant_reflection','learned_rule','open_thread')
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
  SELECT to_jsonb(mom)||jsonb_build_object('source_table','cogcor_chat_bridge.moments','context_types',(SELECT coalesce(jsonb_agg(DISTINCT cr.context_type),'["unspecified"]'::jsonb) FROM cogcor_learning_private.capture_receipts cr WHERE cr.moment_id=mom.id)) INTO m FROM cogcor_chat_bridge.moments mom WHERE id=q.moment_id;
 END IF;
 UPDATE public.job_runs SET input_summary=jsonb_build_object('test_only',c.namespace='test','moment_id',q.moment_id,'model_calls_reserved',CASE WHEN c.namespace='production' THEN 1 ELSE 0 END) WHERE id=r;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(r,'claim','completed',1,1,jsonb_build_object('source_records',jsonb_build_array(jsonb_build_object('table',CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test.moments' ELSE 'cogcor_chat_bridge.moments' END,'id',q.moment_id::text,'role','supporting')),'test_only',c.namespace='test'),now());
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,run_id,status) VALUES('job_started',q.moment_id,r,'running');
 RETURN jsonb_build_object('status','claimed','namespace',c.namespace,'run_id',r,'event',m,'inference_approved',c.inference_approved);
END; $function$
;

-- Source receipts supplement existing remember(); they never rewrite original memories.
CREATE TABLE cogcor_learning_private.capture_receipts(
 conversation_ref text NOT NULL CHECK(length(conversation_ref) BETWEEN 1 AND 200),
 message_ref text NOT NULL CHECK(length(message_ref) BETWEEN 1 AND 200),
 moment_id bigint NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 occurred_at timestamptz, context_type text NOT NULL CHECK(context_type IN ('real','hypothetical','fiction')),
 payload_hash text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(conversation_ref,message_ref)
);
CREATE TABLE cogcor_learning_private.provisional_corrections(
 candidate_id uuid NOT NULL REFERENCES public.cognitive_proposals(id),
 correction_event_id bigint NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(candidate_id,correction_event_id)
);
CREATE TABLE cogcor_learning_private.provisional_applications(
 id uuid PRIMARY KEY, candidate_id uuid NOT NULL REFERENCES public.cognitive_proposals(id),
 conversation_ref text NOT NULL CHECK(length(conversation_ref) BETWEEN 1 AND 200),
 stage text NOT NULL CHECK(stage IN ('retrieved','selected','applied','outcome_observed','scored')),
 applicability text, decision_ref text, observation_id bigint REFERENCES cogcor_chat_bridge.moments(id),
 evaluation text CHECK(evaluation IN ('helped','not_helped','uncertain')), evaluation_evidence text,
 created_at timestamptz NOT NULL DEFAULT now(), applied_at timestamptz, observed_at timestamptz, scored_at timestamptz
);
ALTER TABLE cogcor_learning_private.capture_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.provisional_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_learning_private.provisional_applications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cogcor_learning_private.capture_receipts,cogcor_learning_private.provisional_corrections,cogcor_learning_private.provisional_applications FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON cogcor_learning_private.capture_receipts,cogcor_learning_private.provisional_corrections,cogcor_learning_private.provisional_applications TO service_role;

CREATE FUNCTION public.cogcor_learning_capture_v1(p_conversation text,p_message text,p_occurred_at timestamptz,p_kind text,p_content text,p_quote text,p_evidence text,p_context text DEFAULT 'real')
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE receipt cogcor_learning_private.capture_receipts; m bigint; digest text; stored boolean:=false; result record;
BEGIN
 IF p_conversation IS NULL OR length(btrim(p_conversation)) NOT BETWEEN 1 AND 200 OR p_message IS NULL OR length(btrim(p_message)) NOT BETWEEN 1 AND 200
 OR p_occurred_at>now()+interval '5 minutes' OR p_context IS NULL OR p_context NOT IN ('real','hypothetical','fiction') THEN RAISE EXCEPTION 'invalid_capture_source'; END IF;
 digest:=md5(jsonb_build_array(p_kind,p_content,p_quote,p_evidence,p_context,p_occurred_at)::text);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_conversation||':'||p_message,0));
 SELECT * INTO receipt FROM cogcor_learning_private.capture_receipts WHERE conversation_ref=p_conversation AND message_ref=p_message;
 IF FOUND THEN
  IF receipt.payload_hash<>digest THEN RAISE EXCEPTION 'capture_replay_conflict'; END IF;
  RETURN jsonb_build_object('moment_id',receipt.moment_id,'stored',false,'source_ref','cogcor_chat_bridge:moments:'||receipt.moment_id);
 END IF;
 -- Content-level lock closes duplicate capture races across different message references.
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_kind,p_content,p_quote,p_evidence)::text,1));
 SELECT id INTO m FROM cogcor_chat_bridge.moments WHERE origin='chatgpt_yuna_normal' AND memory_kind=p_kind AND memory_content=p_content AND source_quote IS NOT DISTINCT FROM p_quote AND evidence_type=p_evidence ORDER BY id LIMIT 1;
 IF m IS NULL THEN
  SELECT * INTO result FROM cogcor_chat_bridge.remember(p_kind,p_content,p_quote,p_evidence,'chatgpt_yuna_normal');
  m:=split_part(result.memory_source,':',3)::bigint;stored:=result.stored;
 END IF;
 INSERT INTO cogcor_learning_private.capture_receipts VALUES(p_conversation,p_message,m,p_occurred_at,p_context,digest,now());
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,status) VALUES('experience_captured',m,CASE WHEN stored THEN 'stored' ELSE 'linked_existing' END);
 RETURN jsonb_build_object('moment_id',m,'stored',stored,'source_ref','cogcor_chat_bridge:moments:'||m,'evidence_type',p_evidence,'context_type',p_context);
END $$;

CREATE FUNCTION public.cogcor_learning_provisional_context_v1(p_query text,p_limit integer DEFAULT 5)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT (public.cogcor_learning_context_v1(p_query,p_limit)-'unreviewed_candidates')||jsonb_build_object(
 'provisional_candidates',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(
  SELECT p.id candidate_id,p.proposed_content,p.confidence,m.id source_event_id,m.evidence_type,m.source_quote,m.recorded_at,
    p.source_records,'provisional_not_confirmed_fact' evidence_class,
    coalesce((SELECT jsonb_agg(DISTINCT r.context_type) FROM cogcor_learning_private.capture_receipts r WHERE r.moment_id=m.id),'["unspecified"]'::jsonb) context_types,
    cogcor_learning_private.rank_text(p_query,p.proposed_content||' '||m.memory_content) relevance
  FROM public.cognitive_proposals p JOIN public.job_runs j ON j.id=p.job_run_id
  JOIN cogcor_chat_bridge.moments m ON p.source_records @> jsonb_build_array(jsonb_build_object('table','cogcor_chat_bridge.moments','id',m.id::text))
  WHERE p.status='pending' AND p.proposal_type='orphan' AND j.status='completed' AND j.job_name='cogcor_pseudo_daemon_v1:production'
   AND NOT EXISTS(SELECT 1 FROM cogcor_learning_private.provisional_corrections c WHERE c.candidate_id=p.id)
   AND NOT EXISTS(SELECT 1 FROM cogcor_learning_private.reviews r WHERE r.candidate_id=p.id AND r.state IN ('held','rejected','approved'))
   AND length(p_query) BETWEEN 2 AND 300
   AND cogcor_learning_private.rank_text(p_query,p.proposed_content||' '||m.memory_content)>=0.3
  ORDER BY relevance DESC,p.created_at DESC LIMIT greatest(1,least(coalesce(p_limit,5),10)))x),'[]'::jsonb),
 'corrections',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM(
   SELECT c.candidate_id,m.id correction_event_id,m.memory_content,m.source_quote,m.evidence_type,m.recorded_at
   FROM cogcor_learning_private.provisional_corrections c JOIN cogcor_chat_bridge.moments m ON m.id=c.correction_event_id
   JOIN public.cognitive_proposals p ON p.id=c.candidate_id
   WHERE cogcor_learning_private.rank_text(p_query,p.proposed_content||' '||m.memory_content)>=0.3
   ORDER BY m.recorded_at DESC LIMIT 10)x),'[]'::jsonb),
 'memories',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM public.cogcor_learning_search_v1(p_query,least(coalesce(p_limit,5),10)) x),'[]'::jsonb),
 'priority','current_user_statement_then_corrections_then_sourced_provisional_learning',
 'retrieval_is_application',false)
$$;

CREATE FUNCTION public.cogcor_learning_correct_v1(p_candidate uuid,p_event bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE m cogcor_chat_bridge.moments; p public.cognitive_proposals;
BEGIN
 SELECT * INTO p FROM public.cognitive_proposals WHERE id=p_candidate FOR UPDATE;
 IF NOT FOUND OR p.proposal_type<>'orphan' THEN RAISE EXCEPTION 'candidate_missing'; END IF;
 SELECT * INTO m FROM cogcor_chat_bridge.moments WHERE id=p_event;
 IF NOT FOUND OR m.origin<>'chatgpt_yuna_normal' OR m.evidence_type<>'user_direct' OR nullif(btrim(m.source_quote),'') IS NULL OR m.recorded_at<p.created_at
 OR EXISTS(SELECT 1 FROM cogcor_learning_private.capture_receipts r WHERE r.moment_id=m.id AND r.context_type<>'real') THEN RAISE EXCEPTION 'direct_current_correction_required'; END IF;
 INSERT INTO cogcor_learning_private.provisional_corrections(candidate_id,correction_event_id) VALUES(p_candidate,p_event) ON CONFLICT DO NOTHING;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) SELECT 'provisional_corrected',p_event,p_candidate,'held' WHERE NOT EXISTS(SELECT 1 FROM cogcor_learning_private.audit WHERE event_type='provisional_corrected' AND event_id=p_event AND ref_id=p_candidate);
 RETURN jsonb_build_object('candidate_id',p_candidate,'status','held_for_correction','correction_event_id',p_event,'original_preserved',true);
END $$;

CREATE FUNCTION public.cogcor_learning_provisional_apply_v1(p_id uuid,p_candidate uuid,p_conversation text,p_stage text,p_evidence text DEFAULT NULL,p_observation bigint DEFAULT NULL,p_evaluation text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE a cogcor_learning_private.provisional_applications; m cogcor_chat_bridge.moments;
BEGIN
 IF p_id IS NULL OR p_candidate IS NULL OR p_stage IS NULL OR p_stage NOT IN ('retrieved','selected','applied','outcome_observed','scored') THEN RAISE EXCEPTION 'invalid_application'; END IF;
 -- Serialize against corrections without modifying candidate content or status.
 PERFORM 1 FROM public.cognitive_proposals WHERE id=p_candidate FOR SHARE;
 IF p_stage IN ('retrieved','selected','applied') AND (NOT EXISTS(
  SELECT 1 FROM public.cognitive_proposals p JOIN public.job_runs j ON j.id=p.job_run_id WHERE p.id=p_candidate AND p.status='pending' AND p.proposal_type='orphan' AND j.status='completed' AND j.job_name='cogcor_pseudo_daemon_v1:production'
   AND EXISTS(SELECT 1 FROM cogcor_chat_bridge.moments source_m WHERE p.source_records @> jsonb_build_array(jsonb_build_object('table','cogcor_chat_bridge.moments','id',source_m.id::text))))
  OR EXISTS(SELECT 1 FROM cogcor_learning_private.provisional_corrections WHERE candidate_id=p_candidate)
  OR EXISTS(SELECT 1 FROM cogcor_learning_private.reviews WHERE candidate_id=p_candidate AND state IN ('held','rejected','approved'))) THEN RAISE EXCEPTION 'provisional_not_available'; END IF;
 IF p_stage='retrieved' THEN
 INSERT INTO cogcor_learning_private.provisional_applications(id,candidate_id,conversation_ref,stage) VALUES(p_id,p_candidate,p_conversation,'retrieved') ON CONFLICT DO NOTHING;
 IF FOUND THEN INSERT INTO cogcor_learning_private.audit(event_type,ref_id,status) VALUES('provisional_retrieved',p_id,'retrieved'); END IF; END IF;
 SELECT * INTO a FROM cogcor_learning_private.provisional_applications WHERE id=p_id FOR UPDATE;
 IF NOT FOUND OR a.candidate_id<>p_candidate OR a.conversation_ref IS DISTINCT FROM p_conversation THEN RAISE EXCEPTION 'application_identity'; END IF;
 IF a.stage=p_stage THEN
  IF (p_stage='selected' AND a.applicability IS DISTINCT FROM p_evidence) OR (p_stage='applied' AND a.decision_ref IS DISTINCT FROM p_evidence) OR (p_stage='outcome_observed' AND a.observation_id IS DISTINCT FROM p_observation) OR (p_stage='scored' AND (a.evaluation IS DISTINCT FROM p_evaluation OR a.evaluation_evidence IS DISTINCT FROM p_evidence)) THEN RAISE EXCEPTION 'conflicting_replay'; END IF;
  RETURN jsonb_build_object('application_id',a.id,'stage',a.stage,'changed',false);
 END IF;
 IF p_stage='selected' AND a.stage='retrieved' AND length(btrim(p_evidence)) BETWEEN 5 AND 1000 THEN
  UPDATE cogcor_learning_private.provisional_applications SET stage=p_stage,applicability=p_evidence WHERE id=a.id;
 ELSIF p_stage='applied' AND a.stage='selected' AND length(btrim(p_evidence)) BETWEEN 1 AND 200 THEN
  UPDATE cogcor_learning_private.provisional_applications SET stage=p_stage,decision_ref=p_evidence,applied_at=now() WHERE id=a.id;
 ELSIF p_stage='outcome_observed' AND a.stage='applied' THEN
  SELECT * INTO m FROM cogcor_chat_bridge.moments WHERE id=p_observation;
  IF NOT FOUND OR m.origin<>'chatgpt_yuna_normal' OR m.evidence_type NOT IN ('user_direct','observed_result') OR nullif(btrim(m.source_quote),'') IS NULL OR m.recorded_at<a.applied_at OR EXISTS(SELECT 1 FROM cogcor_learning_private.capture_receipts r WHERE r.moment_id=m.id AND r.context_type<>'real') THEN RAISE EXCEPTION 'later_observation_required'; END IF;
  UPDATE cogcor_learning_private.provisional_applications SET stage=p_stage,observation_id=m.id,observed_at=now() WHERE id=a.id;
 ELSIF p_stage='scored' AND a.stage='outcome_observed' AND p_evaluation IN ('helped','not_helped','uncertain') THEN
  IF current_user NOT IN ('postgres','supabase_admin') THEN RAISE EXCEPTION 'human_evaluation_required'; END IF;
  SELECT * INTO STRICT m FROM cogcor_chat_bridge.moments WHERE id=a.observation_id;
  IF p_evidence IS NULL OR length(btrim(p_evidence))<3 OR strpos(m.source_quote,p_evidence)=0 THEN RAISE EXCEPTION 'evaluation_quote_required'; END IF;
  UPDATE cogcor_learning_private.provisional_applications SET stage=p_stage,evaluation=p_evaluation,evaluation_evidence=p_evidence,scored_at=now() WHERE id=a.id;
 ELSE RAISE EXCEPTION 'invalid_transition'; END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) VALUES('provisional_'||p_stage,p_observation,a.id,p_stage);
 RETURN jsonb_build_object('application_id',a.id,'stage',p_stage,'evidence_class','agent_reported_application_user_sourced_outcome','formal_skill_promoted',false);
END $$;

REVOKE ALL ON FUNCTION public.cogcor_learning_capture_v1(text,text,timestamptz,text,text,text,text,text),public.cogcor_learning_provisional_context_v1(text,integer),public.cogcor_learning_correct_v1(uuid,bigint),public.cogcor_learning_provisional_apply_v1(uuid,uuid,text,text,text,bigint,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_learning_capture_v1(text,text,timestamptz,text,text,text,text,text),public.cogcor_learning_provisional_context_v1(text,integer),public.cogcor_learning_correct_v1(uuid,bigint),public.cogcor_learning_provisional_apply_v1(uuid,uuid,text,text,text,bigint,text) TO service_role;

ALTER TABLE cogcor_learning_private.audit DROP CONSTRAINT audit_event_type_check;
ALTER TABLE cogcor_learning_private.audit ADD CONSTRAINT audit_event_type_check CHECK(event_type IN ('cron_triggered','reservation_status','job_started','job_finished','inference_completed','inference_failed','candidate_created','skill_adopted','skill_retrieved','skill_selected','skill_applied','outcome_observed','outcome_scored','finalize_status','failure_reason','experience_captured','provisional_corrected','provisional_retrieved','provisional_selected','provisional_applied','provisional_outcome_observed','provisional_scored'));

CREATE INDEX capture_receipts_moment_idx ON cogcor_learning_private.capture_receipts(moment_id);
CREATE INDEX provisional_applications_candidate_idx ON cogcor_learning_private.provisional_applications(candidate_id);
