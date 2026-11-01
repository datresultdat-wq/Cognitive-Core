-- Synthetic local database only. Embeddings use text in this harness; no vector behavior is claimed.
CREATE SCHEMA extensions; CREATE EXTENSION pg_trgm WITH SCHEMA extensions;
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA cogcor_chat_bridge; CREATE SCHEMA cogcor_daemon_private; CREATE SCHEMA cogcor_daemon_test;
CREATE TABLE cogcor_chat_bridge.moments (
"id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
"recorded_at" timestamp with time zone DEFAULT now() NOT NULL,
"event_date" date DEFAULT ((now() AT TIME ZONE 'Asia/Tokyo'::text))::date NOT NULL,
"memory_kind" text NOT NULL,
"evidence_type" text NOT NULL,
"memory_content" text NOT NULL,
"source_quote" text,
"origin" text DEFAULT 'chatgpt_yuna_normal'::text NOT NULL,
"fingerprint" text GENERATED ALWAYS AS (md5(((((((memory_kind || '
'::text) || evidence_type) || '
'::text) || memory_content) || '
'::text) || COALESCE(source_quote, ''::text)))) STORED
);
CREATE TABLE cogcor_daemon_private.control (
"id" boolean DEFAULT true NOT NULL,
"enabled" boolean DEFAULT false NOT NULL,
"namespace" text DEFAULT 'test'::text NOT NULL,
"inference_approved" boolean DEFAULT false NOT NULL,
"daily_limit" integer DEFAULT 24 NOT NULL,
"manual_approval_id" uuid,
"manual_moment_id" bigint,
"manual_approval_expires_at" timestamp with time zone,
"auto_enabled" boolean DEFAULT false NOT NULL,
"auto_started_at" timestamp with time zone,
"auto_approval_id" uuid,
"auto_moment_id" bigint,
"auto_reserved_at" timestamp with time zone,
"auto_last_status" text
);
CREATE TABLE cogcor_daemon_private.queue (
"namespace" text NOT NULL,
"moment_id" bigint NOT NULL,
"status" text DEFAULT 'pending'::text NOT NULL,
"attempts" integer DEFAULT 0 NOT NULL,
"run_id" uuid,
"available_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE cogcor_daemon_test.moments (
"id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
"recorded_at" timestamp with time zone DEFAULT now() NOT NULL,
"event_date" date DEFAULT ((now() AT TIME ZONE 'Asia/Tokyo'::text))::date NOT NULL,
"memory_kind" text NOT NULL,
"evidence_type" text NOT NULL,
"memory_content" text NOT NULL,
"source_quote" text,
"origin" text DEFAULT 'chatgpt_yuna_normal'::text NOT NULL,
"fingerprint" text GENERATED ALWAYS AS (md5(((((((memory_kind || '
'::text) || evidence_type) || '
'::text) || memory_content) || '
'::text) || COALESCE(source_quote, ''::text)))) STORED
);
CREATE TABLE public.cognitive_proposals (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"proposal_type" text NOT NULL,
"proposed_content" text NOT NULL,
"rationale" text,
"confidence" numeric DEFAULT 0.5 NOT NULL,
"source_records" jsonb NOT NULL,
"status" text DEFAULT 'pending'::text NOT NULL,
"accepted_content" text,
"accepted_record_table" text,
"accepted_record_id" uuid,
"job_run_id" uuid,
"resolved_at" timestamp with time zone,
"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public.job_runs (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"job_name" text NOT NULL,
"scheduled_for" timestamp with time zone,
"status" text DEFAULT 'running'::text NOT NULL,
"trigger_source" text DEFAULT 'scheduler'::text NOT NULL,
"input_summary" jsonb DEFAULT '{}'::jsonb NOT NULL,
"output_summary" jsonb DEFAULT '{}'::jsonb NOT NULL,
"error_summary" text,
"started_at" timestamp with time zone DEFAULT now() NOT NULL,
"finished_at" timestamp with time zone,
"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public.job_stages (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"job_run_id" uuid NOT NULL,
"stage_name" text NOT NULL,
"status" text DEFAULT 'running'::text NOT NULL,
"input_count" integer DEFAULT 0 NOT NULL,
"output_count" integer DEFAULT 0 NOT NULL,
"receipt" jsonb DEFAULT '{}'::jsonb NOT NULL,
"error_summary" text,
"started_at" timestamp with time zone DEFAULT now() NOT NULL,
"finished_at" timestamp with time zone
);
CREATE TABLE public.metacognition_log (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"level" integer NOT NULL,
"pathway" text NOT NULL,
"monitoring" text NOT NULL,
"prediction" text,
"actual" text,
"prediction_error" numeric,
"precision" numeric,
"control_action" text,
"stability_impact" text,
"identity_owner" text NOT NULL,
"loop_references" jsonb DEFAULT '[]'::jsonb,
"emotional_state_at" jsonb,
"source" text DEFAULT 'claude'::text,
"created_at" timestamp with time zone DEFAULT now()
);
CREATE TABLE public.outcome_scores (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"target_type" text NOT NULL,
"target_id" uuid,
"description" text NOT NULL,
"score" integer,
"notes" text,
"source" text DEFAULT 'claude'::text,
"created_at" timestamp with time zone DEFAULT now()
);
CREATE TABLE public.reflections (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"content" text NOT NULL,
"inputs_summary" text,
"reflection_type" text,
"depth" integer DEFAULT 0,
"source" text DEFAULT 'claude'::text,
"created_at" timestamp with time zone DEFAULT now(),
"prediction" text,
"prediction_outcome" text,
"calibration_score" numeric,
"embedding" text,
"outcome_score" real DEFAULT 0
);
CREATE TABLE public.skills (
"id" uuid DEFAULT gen_random_uuid() NOT NULL,
"skill_name" text NOT NULL,
"description" text NOT NULL,
"approach" text NOT NULL,
"trigger_context" text,
"times_used" integer DEFAULT 0,
"times_succeeded" integer DEFAULT 0,
"times_failed" integer DEFAULT 0,
"effectiveness" real DEFAULT 0.5,
"tags" jsonb DEFAULT '[]'::jsonb,
"source" text DEFAULT 'claude'::text,
"embedding" text,
"created_at" timestamp with time zone DEFAULT now(),
"updated_at" timestamp with time zone DEFAULT now(),
"status" text DEFAULT 'active'::text NOT NULL,
"last_used_at" timestamp with time zone
);
ALTER TABLE cogcor_daemon_private.control ADD PRIMARY KEY(id);
ALTER TABLE cogcor_daemon_private.queue ADD PRIMARY KEY(namespace,moment_id);
ALTER TABLE cogcor_chat_bridge.moments ADD PRIMARY KEY(id),ADD CONSTRAINT moments_unique_daily UNIQUE(event_date,fingerprint);
ALTER TABLE cogcor_daemon_test.moments ADD PRIMARY KEY(id);
ALTER TABLE public.job_runs ADD PRIMARY KEY(id),ADD UNIQUE(job_name,scheduled_for);
ALTER TABLE public.job_stages ADD PRIMARY KEY(id),ADD UNIQUE(job_run_id,stage_name);
ALTER TABLE public.cognitive_proposals ADD PRIMARY KEY(id);
ALTER TABLE public.skills ADD PRIMARY KEY(id);
ALTER TABLE public.outcome_scores ADD PRIMARY KEY(id);
INSERT INTO cogcor_daemon_private.control(id,namespace,daily_limit) VALUES(true,'production',1);
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

CREATE OR REPLACE FUNCTION public.cogcor_daemon_learning_context_v1(p_query text, p_limit integer DEFAULT 5)
 RETURNS TABLE(id uuid, content text, source_records jsonb, review_status text, interpretation_status text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT p.id,p.proposed_content,p.source_records,p.status,'ai_interpretation_not_user_fact'::text
 FROM public.cognitive_proposals p JOIN public.job_runs j ON j.id=p.job_run_id
 WHERE j.job_name='cogcor_pseudo_daemon_v1:production' AND j.status='completed'
 AND p.status IN ('pending','accepted') AND length(btrim(p_query)) BETWEEN 1 AND 120
 AND strpos(lower(p.proposed_content||' '||coalesce(p.rationale,'')),lower(btrim(p_query)))>0
 ORDER BY p.created_at DESC LIMIT greatest(1,least(coalesce(p_limit,5),8));
$function$;

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

CREATE OR REPLACE FUNCTION cogcor_chat_bridge.remember(p_kind text, p_content text, p_source_quote text DEFAULT NULL::text, p_evidence_type text DEFAULT 'conversation_summary'::text, p_origin text DEFAULT 'chatgpt_yuna_normal'::text)
 RETURNS TABLE(stored boolean, memory_source text, event_date date)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE v_id bigint; v_date date; v_fingerprint text;
BEGIN
 IF p_kind IS NULL OR p_kind NOT IN ('conversation_event','user_fact','assistant_reflection','learned_rule','open_thread') THEN
  RAISE EXCEPTION 'Invalid memory kind';
 END IF;
 IF p_evidence_type IS NULL OR p_evidence_type NOT IN ('user_direct','observed_result','assistant_interpretation','conversation_summary') THEN
  RAISE EXCEPTION 'Invalid evidence type';
 END IF;
 IF p_content IS NULL OR length(btrim(p_content)) < 1 OR length(p_content) > 1600 THEN
  RAISE EXCEPTION 'Invalid memory content size';
 END IF;
 IF p_source_quote IS NOT NULL AND length(p_source_quote)>800 THEN
  RAISE EXCEPTION 'Source quote too long';
 END IF;
 IF p_origin IS NULL OR length(p_origin) NOT BETWEEN 1 AND 160 THEN
  RAISE EXCEPTION 'Invalid origin';
 END IF;
 IF p_kind='learned_rule' AND p_evidence_type NOT IN ('user_direct','observed_result') THEN
  RAISE EXCEPTION 'Learned rule needs direct correction or observed result';
 END IF;
 IF p_evidence_type='user_direct' AND coalesce(length(btrim(p_source_quote)),0)=0 THEN
  RAISE EXCEPTION 'Direct user evidence needs a verbatim quote';
 END IF;
 v_date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
 v_fingerprint := md5(p_kind || E'\n' || p_evidence_type || E'\n' || p_content || E'\n' || coalesce(p_source_quote,''));
 INSERT INTO cogcor_chat_bridge.moments(event_date,memory_kind,memory_content,source_quote,evidence_type,origin)
 VALUES(v_date,p_kind,p_content,p_source_quote,p_evidence_type,p_origin)
 ON CONFLICT ON CONSTRAINT moments_unique_daily DO NOTHING
 RETURNING id INTO v_id;
 IF v_id IS NOT NULL THEN
  RETURN QUERY SELECT true,'cogcor_chat_bridge:moments:'||v_id,v_date;
 ELSE
  RETURN QUERY SELECT false, 'cogcor_chat_bridge:moments:'||m.id, m.event_date
  FROM cogcor_chat_bridge.moments m WHERE m.event_date=v_date AND m.fingerprint=v_fingerprint LIMIT 1;
 END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cogcor_processing_moments_v1(p_hours integer DEFAULT 24, p_limit integer DEFAULT 10)
 RETURNS TABLE(id bigint, recorded_at timestamp with time zone, event_date date, memory_kind text, evidence_type text, memory_content text, source_quote text, origin text, source_ref text, source_record jsonb, verification text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 SELECT m.id,m.recorded_at,m.event_date,m.memory_kind,m.evidence_type,m.memory_content,m.source_quote,m.origin,
 'cogcor_chat_bridge:moments:'||m.id,
 jsonb_build_object('table','cogcor_chat_bridge.moments','id',m.id::text,'role','supporting','evidence_type',m.evidence_type),
 'caller_attributed_not_independently_verified'::text
 FROM cogcor_chat_bridge.moments m
 WHERE m.origin='chatgpt_yuna_normal'
 AND m.recorded_at>=now()-make_interval(hours=>greatest(1,least(coalesce(p_hours,24),72)))
 ORDER BY m.recorded_at DESC,m.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,10),20));
$function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_outcomes_v1(p_hours integer DEFAULT 24, p_limit integer DEFAULT 3)
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
 WHERE o.target_type='cogcor_learning_candidate' AND o.source='chatgpt_yuna_normal'
 AND o.score IN (-1,1) AND j.job_name='cogcor_pseudo_daemon_v1:production' AND j.status='completed'
 AND p.status IN ('pending','accepted') AND p.proposal_type='orphan' AND p.rationale LIKE '%learning_candidate%'
 AND jsonb_array_length(p.source_records)>0
 AND m.origin='chatgpt_yuna_normal' AND m.evidence_type IN ('user_direct','observed_result')
 AND nullif(btrim(m.source_quote),'') IS NOT NULL AND m.recorded_at>=p.created_at AND o.created_at>=m.recorded_at
 AND o.created_at>=now()-make_interval(hours=>greatest(1,least(coalesce(p_hours,24),72)))
 ORDER BY o.created_at DESC,o.id LIMIT greatest(1,least(coalesce(p_limit,3),3));
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

CREATE OR REPLACE FUNCTION public.cogcor_daemon_test_io_v1(p_table text, p_op text, p_data jsonb, p_filter jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
END; $function$;

CREATE OR REPLACE FUNCTION cogcor_chat_bridge.record_learning_outcome(p_candidate_id uuid, p_observation_moment_id bigint, p_helped boolean)
 RETURNS TABLE(saved boolean, outcome_id uuid)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_proposal record;
  v_moment record;
  v_existing uuid;
  v_id uuid;
  v_ref text;
BEGIN
  IF p_candidate_id IS NULL OR p_observation_moment_id IS NULL OR p_helped IS NULL THEN
    RAISE EXCEPTION 'All parameters are required';
  END IF;
  SELECT p.id,p.created_at,p.status INTO v_proposal
  FROM public.cognitive_proposals p
  JOIN public.job_runs j ON j.id=p.job_run_id
  WHERE p.id=p_candidate_id AND j.job_name='cogcor_pseudo_daemon_v1:production'
    AND j.status='completed' AND p.status IN ('pending','accepted')
    AND p.proposal_type='orphan' AND p.rationale LIKE '%learning_candidate%'
  FOR UPDATE OF p;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a completed, sourced production learning candidate';
  END IF;
  SELECT m.id,m.recorded_at,m.evidence_type,m.source_quote,m.memory_content INTO v_moment
  FROM cogcor_chat_bridge.moments m
  WHERE m.id=p_observation_moment_id AND m.origin='chatgpt_yuna_normal';
  IF NOT FOUND OR v_moment.evidence_type NOT IN ('user_direct','observed_result')
     OR nullif(btrim(v_moment.source_quote),'') IS NULL THEN
    RAISE EXCEPTION 'Observed outcome requires a sourced direct statement';
  END IF;
  IF v_moment.recorded_at < v_proposal.created_at THEN
    RAISE EXCEPTION 'Outcome observation predates learning candidate';
  END IF;
  v_ref:='cogcor_chat_bridge:moments:'||v_moment.id::text;
  SELECT o.id INTO v_existing FROM public.outcome_scores o
  WHERE o.target_type='cogcor_learning_candidate'
    AND o.target_id=p_candidate_id AND o.source='chatgpt_yuna_normal'
    AND o.notes=v_ref
  LIMIT 1;
  IF FOUND THEN
    RETURN QUERY SELECT false,v_existing;
    RETURN;
  END IF;
  INSERT INTO public.outcome_scores(target_type,target_id,description,score,notes,source)
  VALUES('cogcor_learning_candidate',p_candidate_id,
         'Observed candidate effect; compare the linked original user statement',
         CASE WHEN p_helped THEN 1 ELSE -1 END,v_ref,'chatgpt_yuna_normal')
  RETURNING id INTO v_id;
  RETURN QUERY SELECT true,v_id;
END;
$function$;

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

GRANT USAGE ON SCHEMA cogcor_daemon_private,cogcor_chat_bridge TO service_role;GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public,cogcor_daemon_private,cogcor_chat_bridge TO service_role;
