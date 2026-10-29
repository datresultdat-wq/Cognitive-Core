-- Operational execution state only. Existing memory/identity rows are untouched.
BEGIN;
CREATE SCHEMA cogcor_daemon_private;
CREATE SCHEMA cogcor_daemon_test;
REVOKE ALL ON SCHEMA cogcor_daemon_private,cogcor_daemon_test FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA cogcor_daemon_private,cogcor_daemon_test TO service_role;
CREATE TABLE cogcor_daemon_private.control (
 id boolean PRIMARY KEY DEFAULT true CHECK(id), enabled boolean NOT NULL DEFAULT false,
 namespace text NOT NULL DEFAULT 'test' CHECK(namespace IN ('test','production')),
 inference_approved boolean NOT NULL DEFAULT false,
 daily_limit integer NOT NULL DEFAULT 24 CHECK(daily_limit BETWEEN 1 AND 48)
);
INSERT INTO cogcor_daemon_private.control(id) VALUES(true);
CREATE TABLE cogcor_daemon_private.queue (
 namespace text NOT NULL CHECK(namespace IN ('test','production')),
 moment_id bigint NOT NULL,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','needs_review')),
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 run_id uuid REFERENCES public.job_runs(id), available_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(namespace,moment_id)
);
CREATE TABLE cogcor_daemon_test.moments (LIKE cogcor_chat_bridge.moments INCLUDING ALL);
ALTER TABLE cogcor_daemon_test.moments ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT ON cogcor_daemon_test.moments TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA cogcor_daemon_test TO service_role;
CREATE UNIQUE INDEX cogcor_daemon_slot_once ON public.job_runs(job_name,scheduled_for)
 WHERE job_name IN ('cogcor_pseudo_daemon_v1:test','cogcor_pseudo_daemon_v1:production');
-- Real isolated tables with the same column/check/default contracts; never exposed as Data API schemas.
DO $body$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['reflections','metacognition_log','skills','companion_preferences','outcome_scores','cognitive_proposals'] LOOP
  EXECUTE format('CREATE TABLE cogcor_daemon_test.%I (LIKE public.%I INCLUDING ALL)',t,t);
  EXECUTE format('ALTER TABLE cogcor_daemon_test.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('GRANT SELECT,INSERT,UPDATE ON cogcor_daemon_test.%I TO service_role',t);
 END LOOP;
END; $body$;
ALTER TABLE cogcor_daemon_private.control ENABLE ROW LEVEL SECURITY;
ALTER TABLE cogcor_daemon_private.queue ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA cogcor_daemon_private TO service_role;

CREATE FUNCTION public.cogcor_daemon_claim_v1(p_tick timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
DECLARE c cogcor_daemon_private.control; q cogcor_daemon_private.queue; r uuid; m jsonb; n integer; slot timestamptz;
BEGIN
 SELECT * INTO c FROM cogcor_daemon_private.control WHERE id FOR UPDATE;
 IF NOT c.enabled THEN RETURN jsonb_build_object('status','disabled'); END IF;
 IF c.namespace='production' AND NOT c.inference_approved THEN RETURN jsonb_build_object('status','approval_required'); END IF;
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
 VALUES('cogcor_pseudo_daemon_v1:'||c.namespace,slot,'cloudflare_cron',jsonb_build_object('test_only',c.namespace='test','max_events',1))
 ON CONFLICT DO NOTHING RETURNING id INTO r;
 IF r IS NULL THEN RETURN jsonb_build_object('status','duplicate_tick'); END IF;
 INSERT INTO cogcor_daemon_private.queue(namespace,moment_id)
 SELECT c.namespace,mom.id FROM (SELECT id,evidence_type,memory_kind FROM cogcor_daemon_test.moments WHERE c.namespace='test' AND origin='cogcor_daemon_test_v1' UNION ALL SELECT id,evidence_type,memory_kind FROM cogcor_chat_bridge.moments WHERE c.namespace='production' AND origin='chatgpt_yuna_normal') mom
 WHERE true
 AND mom.evidence_type IN ('user_direct','observed_result')
 AND mom.memory_kind IN ('conversation_event','learned_rule','open_thread')
 AND NOT EXISTS(SELECT 1 FROM cogcor_daemon_private.queue existing WHERE existing.namespace=c.namespace AND existing.moment_id=mom.id)
 ORDER BY mom.id LIMIT 100 ON CONFLICT DO NOTHING;
 SELECT * INTO q FROM cogcor_daemon_private.queue WHERE namespace=c.namespace AND status='pending' AND attempts<3 AND available_at<=now() ORDER BY moment_id LIMIT 1 FOR UPDATE SKIP LOCKED;
 IF NOT FOUND THEN
  UPDATE public.job_runs SET status='skipped',finished_at=now(),output_summary='{"reason":"no_unprocessed_event"}' WHERE id=r;
  RETURN jsonb_build_object('status','no_unprocessed_event','run_id',r);
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
 RETURN jsonb_build_object('status','claimed','namespace',c.namespace,'run_id',r,'event',m,'inference_approved',c.inference_approved);
END; $body$;

CREATE FUNCTION public.cogcor_daemon_stage_v1(p_run uuid,p_stage text,p_status text,p_receipt jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
BEGIN
 IF p_stage NOT IN ('context','self_model_review','reflection','metacognition','fixture_skill','fixture_self_hypothesis') OR p_status NOT IN ('running','completed') THEN RAISE EXCEPTION 'Invalid stage'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name LIKE 'cogcor_pseudo_daemon_v1:%' AND status='running') THEN RAISE EXCEPTION 'Run not running'; END IF;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,p_stage,p_status,1,CASE WHEN p_status='completed' THEN 1 ELSE 0 END,p_receipt,CASE WHEN p_status='completed' THEN now() END)
 ON CONFLICT(job_run_id,stage_name) DO UPDATE SET status=excluded.status,output_count=excluded.output_count,receipt=excluded.receipt,finished_at=excluded.finished_at;
END; $body$;

CREATE FUNCTION public.cogcor_daemon_candidate_v1(p_run uuid,p_content text,p_question text) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
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
END; $body$;

CREATE FUNCTION public.cogcor_daemon_finish_v1(p_run uuid,p_status text,p_error text,p_retry_safe boolean) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
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
END; $body$;

-- Private test adapter for the SAME native handlers. Table allowlist is local,
-- never supplied by model output. No test record enters public memory pools.
CREATE FUNCTION public.cogcor_daemon_test_io_v1(p_table text,p_op text,p_data jsonb,p_filter jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
DECLARE cols text; sets text; result jsonb;
BEGIN
 IF p_table IN ('session_logs','emotional_history','core_memories','emotional_state') AND p_op='query' THEN RETURN '[]'::jsonb; END IF;
 IF p_table NOT IN ('reflections','metacognition_log','skills','companion_preferences','outcome_scores') THEN RAISE EXCEPTION 'Test table not allowed'; END IF;
 IF p_op='query' THEN
  EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) FROM (SELECT * FROM cogcor_daemon_test.%I x WHERE to_jsonb(x) @> $1 ORDER BY created_at DESC LIMIT 50)t',p_table) INTO result USING coalesce(p_filter,'{}');
 ELSIF p_op='insert' THEN
  SELECT string_agg(format('%I',k),',') INTO cols FROM jsonb_object_keys(p_data) k;
  EXECUTE format('WITH t AS(INSERT INTO cogcor_daemon_test.%I(%s) SELECT %s FROM jsonb_populate_record(NULL::cogcor_daemon_test.%I,$1) RETURNING *) SELECT jsonb_agg(to_jsonb(t)) FROM t',p_table,cols,cols,p_table) INTO result USING p_data;
 ELSIF p_op='update' AND p_filter ? 'id' THEN
  SELECT string_agg(format('%1$I=r.%1$I',k),',') INTO sets FROM jsonb_object_keys(p_data) k;
  EXECUTE format('WITH t AS(UPDATE cogcor_daemon_test.%I x SET %s FROM jsonb_populate_record(NULL::cogcor_daemon_test.%I,$1)r WHERE x.id=($2->>''id'')::uuid RETURNING x.*) SELECT coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) FROM t',p_table,sets,p_table) INTO result USING p_data,p_filter;
 ELSE RAISE EXCEPTION 'Test operation not allowed'; END IF;
 RETURN result;
END; $body$;

CREATE FUNCTION public.cogcor_daemon_learning_context_v1(p_query text,p_limit integer DEFAULT 5) RETURNS TABLE(id uuid,content text,source_records jsonb,review_status text,interpretation_status text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $body$
 SELECT p.id,p.proposed_content,p.source_records,p.status,'ai_interpretation_not_user_fact'::text
 FROM public.cognitive_proposals p JOIN public.job_runs j ON j.id=p.job_run_id
 WHERE j.job_name='cogcor_pseudo_daemon_v1:production' AND j.status='completed'
 AND p.status IN ('pending','accepted') AND length(btrim(p_query)) BETWEEN 1 AND 120
 AND strpos(lower(p.proposed_content||' '||coalesce(p.rationale,'')),lower(btrim(p_query)))>0
 ORDER BY p.created_at DESC LIMIT greatest(1,least(coalesce(p_limit,5),8));
$body$;

DO $body$
DECLARE f regprocedure;
BEGIN
 FOR f IN SELECT oid::regprocedure FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'cogcor_daemon_%_v1' LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f);
 END LOOP;
END; $body$;
COMMIT;
