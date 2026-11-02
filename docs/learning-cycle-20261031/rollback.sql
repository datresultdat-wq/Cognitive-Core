-- NOT EXECUTED. Only after human approval, Cron pause, and fresh backup.
BEGIN;
SET LOCAL lock_timeout='3s';
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN RAISE EXCEPTION 'inspect running job before rollback'; END IF; END $$;
UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false WHERE id;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_finish_v1(p_run uuid, p_status text, p_error text, p_retry_safe boolean)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF p_status NOT IN ('completed','failed') THEN RAISE EXCEPTION 'Invalid finish'; END IF;
 UPDATE cogcor_daemon_private.queue SET status=CASE WHEN p_status='completed' THEN 'completed' WHEN p_retry_safe AND attempts<3 THEN 'pending' ELSE 'needs_review' END,
 available_at=now()+make_interval(mins=>30*attempts)
 WHERE run_id=p_run AND status='running';
 IF NOT FOUND THEN RAISE EXCEPTION 'No matching running claim'; END IF;
 UPDATE public.job_stages SET status='failed',error_summary=left(p_error,150),finished_at=now() WHERE job_run_id=p_run AND status='running';
 UPDATE public.job_runs SET status=CASE WHEN p_status='failed' AND EXISTS(SELECT 1 FROM public.job_stages WHERE job_run_id=p_run AND stage_name IN ('reflection','metacognition') AND status='completed') THEN 'partial' ELSE p_status END,
 error_summary=left(p_error,150),finished_at=now(),output_summary=jsonb_build_object('native_completed_stages',(SELECT count(*) FROM public.job_stages WHERE job_run_id=p_run AND status='completed'),'outcome_observed',false)
 WHERE id=p_run AND status='running';
END; $function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_stage_v1(p_run uuid, p_stage text, p_status text, p_receipt jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF p_stage NOT IN ('context','self_model_review','reflection','metacognition','fixture_skill','fixture_self_hypothesis','inference')
 OR (p_status NOT IN ('running','completed') AND NOT (p_stage='inference' AND p_status='failed')) THEN RAISE EXCEPTION 'Invalid stage'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name LIKE 'cogcor_pseudo_daemon_v1:%' AND status='running') THEN RAISE EXCEPTION 'Run not running'; END IF;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,p_stage,p_status,1,CASE WHEN p_status='completed' THEN 1 ELSE 0 END,p_receipt,CASE WHEN p_status IN ('completed','failed') THEN now() END)
 ON CONFLICT(job_run_id,stage_name) DO UPDATE SET status=excluded.status,output_count=excluded.output_count,receipt=excluded.receipt,finished_at=excluded.finished_at;
END; $function$;

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
 SELECT 'skill',coalesce(source,''),concat_ws(E'\n',skill_name,description,trigger_context,approach),concat_ws(E'\n',skill_name,description,trigger_context,approach) FROM public.skills WHERE status='active'
 UNION ALL
 SELECT 'essence',coalesce(source,''),content,content FROM public.essence WHERE pinned IS TRUE
 UNION ALL
 SELECT 'person',coalesce(source,''),concat_ws(E'\n',name,content),concat_ws(E'\n',name,content) FROM public.people
), scored AS (
 SELECT d.kind,d.src,d.body,greatest(
  CASE WHEN position(i.q in lower(d.searchable))>0 THEN 1.0 ELSE 0.0 END,
  extensions.word_similarity(i.q,lower(d.searchable)),
  extensions.similarity(i.q,lower(d.searchable))
 )::real score
 FROM documents d CROSS JOIN input i WHERE char_length(i.q)>=2
 AND (CASE
 WHEN i.q ~ '[[:space:]　]' THEN NOT EXISTS (
 SELECT 1 FROM regexp_split_to_table(i.q,'[[:space:]　]+') AS token
 WHERE token<>'' AND position(token in lower(d.searchable))=0)
 WHEN char_length(i.q)<=4 AND i.q ~ '[ぁ-んァ-ヶ一-龠]' THEN position(i.q in lower(d.searchable))>0
 ELSE true END)
)
SELECT kind,src,body,score FROM scored WHERE score>=0.25
ORDER BY score DESC,CASE kind WHEN 'conversation_event' THEN 1 WHEN 'user_fact' THEN 1 WHEN 'learned_rule' THEN 1 WHEN 'assistant_reflection' THEN 1 WHEN 'open_thread' THEN 1 WHEN 'inside_joke' THEN 2 WHEN 'creative_or_personal' THEN 3
 WHEN 'pattern' THEN 4 WHEN 'skill' THEN 5 ELSE 6 END,src
LIMIT (SELECT n FROM input);
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
     AND j.trigger_source='manual_approved'
     AND j.started_at>=c.auto_reserved_at
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
   auto_enabled=CASE WHEN p_success AND verified THEN auto_enabled ELSE false END,
   auto_last_status=CASE WHEN p_success AND verified THEN 'completed'
                         ELSE 'paused_after_run' END
 WHERE id=true;
 RETURN jsonb_build_object('status',CASE WHEN p_success AND verified
                                        THEN 'completed' ELSE 'disarmed' END);
END;
$function$;

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
END; $function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_claim_v1(p_tick timestamp with time zone, p_test_only boolean DEFAULT false, p_approval_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE c cogcor_daemon_private.control; q cogcor_daemon_private.queue; r uuid; m jsonb; n integer; slot timestamptz;
BEGIN
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Missing control row'; END IF;
 IF p_tick IS NULL OR p_test_only IS NULL THEN RAISE EXCEPTION 'Missing execution mode'; END IF;
 IF p_test_only AND (c.namespace<>'test' OR c.inference_approved) THEN RETURN jsonb_build_object('status','test_only_required'); END IF;
 IF NOT p_test_only AND c.namespace='test' THEN RETURN jsonb_build_object('status','production_required'); END IF;
 IF NOT c.enabled THEN RETURN jsonb_build_object('status','disabled'); END IF;
 IF c.namespace='production' AND NOT c.inference_approved THEN RETURN jsonb_build_object('status','approval_required'); END IF;
 IF c.namespace='production' AND (p_approval_id IS NULL OR c.manual_approval_id IS DISTINCT FROM p_approval_id OR c.manual_moment_id IS NULL OR c.manual_approval_expires_at IS NULL OR c.manual_approval_expires_at<=now()) THEN RETURN jsonb_build_object('status','approval_required'); END IF;
 -- DB-level lease prevents overlap across Worker instances/redeployments.
 IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND status='running' AND started_at>now()-interval '10 minutes') THEN
  RETURN jsonb_build_object('status','busy');
 END IF;
 UPDATE cogcor_daemon_private.queue SET status='needs_review' WHERE status='running' AND namespace=c.namespace;
 UPDATE public.job_runs SET status='partial',error_summary='Lease expired; inspect receipts before retry',finished_at=now()
 WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND status='running';
 SELECT count(*) INTO n FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:'||c.namespace AND started_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 IF n>=c.daily_limit THEN RETURN jsonb_build_object('status','daily_limit'); END IF;
 slot:=date_trunc('minute',p_tick);
 INSERT INTO public.job_runs(job_name,scheduled_for,trigger_source,input_summary)
 VALUES('cogcor_pseudo_daemon_v1:'||c.namespace,slot,CASE WHEN p_test_only THEN 'manual_test' ELSE 'manual_approved' END,jsonb_build_object('test_only',c.namespace='test','max_events',1))
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
 UPDATE cogcor_daemon_private.queue SET status='running',attempts=attempts+1,run_id=r WHERE namespace=q.namespace AND moment_id=q.moment_id;
 IF c.namespace='test' THEN
  SELECT to_jsonb(mom)||jsonb_build_object('source_table','cogcor_daemon_test.moments') INTO m FROM cogcor_daemon_test.moments mom WHERE id=q.moment_id;
 ELSE
  SELECT to_jsonb(mom)||jsonb_build_object('source_table','cogcor_chat_bridge.moments') INTO m FROM cogcor_chat_bridge.moments mom WHERE id=q.moment_id;
 END IF;
 UPDATE public.job_runs SET input_summary=jsonb_build_object('test_only',c.namespace='test','moment_id',q.moment_id,'model_calls_reserved',CASE WHEN c.namespace='production' THEN 1 ELSE 0 END) WHERE id=r;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(r,'claim','completed',1,1,jsonb_build_object('source_records',jsonb_build_array(jsonb_build_object('table',CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test.moments' ELSE 'cogcor_chat_bridge.moments' END,'id',q.moment_id::text,'role','supporting')),'test_only',c.namespace='test'),now());
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
BEGIN
 IF p_tick IS NULL OR abs(extract(epoch FROM now()-p_tick))>600 THEN
   RETURN jsonb_build_object('status','invalid_tick');
 END IF;
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id=true FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'control_missing'; END IF;
 IF NOT c.auto_enabled THEN RETURN jsonb_build_object('status','disarmed'); END IF;
 IF c.namespace <> 'production' OR c.daily_limit <> 1 OR c.auto_started_at IS NULL OR c.auto_started_at>now() THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,auto_last_status='misconfigured' WHERE id=true;
   RETURN jsonb_build_object('status','misconfigured');
 END IF;
 IF c.auto_approval_id IS NOT NULL THEN
   -- A crashed runner/finalizer cannot silently acquire another event.
   IF c.auto_reserved_at IS NULL OR c.auto_reserved_at<=now()-interval '4 minutes' THEN
     UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false,
       manual_approval_id=NULL,manual_moment_id=NULL,manual_approval_expires_at=NULL,
       auto_last_status='paused_unfinished_reservation' WHERE id=true;
     RETURN jsonb_build_object('status','paused_unfinished_reservation');
   END IF;
   RETURN jsonb_build_object('status','busy_or_pending_approval');
 END IF;
 IF c.enabled OR c.inference_approved OR c.auto_moment_id IS NOT NULL OR c.auto_reserved_at IS NOT NULL
    OR c.manual_approval_id IS NOT NULL OR c.manual_moment_id IS NOT NULL OR c.manual_approval_expires_at IS NOT NULL THEN
   RETURN jsonb_build_object('status','busy_or_pending_approval');
 END IF;
 IF EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,auto_last_status='paused_running_job' WHERE id=true;
   RETURN jsonb_build_object('status','paused_running_job');
 END IF;
 -- Any previous production failure/partial result during the current armed period disables unattended execution.
 IF EXISTS(SELECT 1 FROM public.job_runs j WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
    AND j.status IN ('failed','partial') AND j.started_at>=c.auto_started_at) THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,
     auto_last_status='paused_after_failure' WHERE id=true;
   RETURN jsonb_build_object('status','paused_after_failure');
 END IF;
 -- The DB-level existing claim also enforces the limit. Guard before creating an approval.
 IF (SELECT count(*) FROM public.job_runs j WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
       AND j.started_at>=date_trunc('day',now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') >= 1 THEN
   RETURN jsonb_build_object('status','daily_limit');
 END IF;
 -- Do not pile up unreviewed hypotheses indefinitely.
 IF (SELECT count(*) FROM public.cognitive_proposals p
      JOIN public.job_runs j ON j.id=p.job_run_id
      WHERE j.job_name='cogcor_pseudo_daemon_v1:production'
        AND p.status='pending' AND p.rationale LIKE '%learning_candidate%')>=5 THEN
   UPDATE cogcor_daemon_private.control SET auto_enabled=false,
      auto_last_status='paused_candidate_backlog' WHERE id=true;
   RETURN jsonb_build_object('status','paused_candidate_backlog');
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
 IF event_id IS NULL THEN RETURN jsonb_build_object('status','no_eligible_new_event'); END IF;
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
   auto_last_status='reserved'
 WHERE id=true;
 RETURN jsonb_build_object('status','approved','approval_id',approval);
END;
$function$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA cogcor_learning_private FROM service_role;

REVOKE ALL ON ALL TABLES IN SCHEMA cogcor_learning_private FROM service_role;

REVOKE ALL ON FUNCTION public.cogcor_learning_context_v1(text,integer),public.cogcor_learning_application_v1(uuid,uuid,text,text,text,bigint),public.cogcor_learning_search_v1(text,integer,text,timestamptz,timestamptz,text),public.cogcor_daemon_budget_status_v1(),public.cogcor_daemon_related_outcomes_v1(text,integer,integer) FROM service_role;

COMMIT;
