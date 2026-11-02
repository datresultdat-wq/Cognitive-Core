SET LOCAL lock_timeout='3s';
DO $guard$ BEGIN
 IF EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE auto_enabled OR enabled OR inference_approved OR manual_approval_id IS NOT NULL OR auto_approval_id IS NOT NULL OR auto_reserved_at IS NOT NULL OR auto_moment_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN RAISE EXCEPTION 'Pause and resolve active reservations before migration'; END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_candidate_v1(p_run uuid, p_content text, p_question text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE q cogcor_daemon_private.queue; refs jsonb; target_schema text;
BEGIN
 SELECT * INTO STRICT q FROM cogcor_daemon_private.queue WHERE run_id=p_run AND status='running' FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND status='running' AND started_at>now()-interval '9 minutes') THEN RAISE EXCEPTION 'Run not running'; END IF;
 IF p_content IS NULL OR length(btrim(p_content)) NOT BETWEEN 1 AND 1200 OR (p_question IS NOT NULL AND length(btrim(p_question)) NOT BETWEEN 1 AND 800) THEN RAISE EXCEPTION 'Candidate budget'; END IF;
 refs:=jsonb_build_array(jsonb_build_object('table',CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test.moments' ELSE 'cogcor_chat_bridge.moments' END,'id',q.moment_id::text,'role','supporting'));
 target_schema:=CASE WHEN q.namespace='test' THEN 'cogcor_daemon_test' ELSE 'public' END;
 -- Existing orphan proposal class: a sourced memory/procedure requiring review.
 EXECUTE format('INSERT INTO %I.cognitive_proposals(proposal_type,proposed_content,rationale,confidence,source_records,job_run_id) VALUES(''orphan'',$1,$2,0.3,$3,$4)',target_schema)
 USING p_content,jsonb_build_object('kind','learning_candidate','self_model_question',p_question,'interpretation_status','unreviewed','test_only',q.namespace='test')::text,refs,p_run;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,'candidate','completed',1,1,jsonb_build_object('source_records',refs,'review_required',true,'test_only',q.namespace='test'),now());
INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('candidate_created',p_run,'pending');
END; $function$;

CREATE OR REPLACE FUNCTION public.cogcor_daemon_stage_v1(p_run uuid, p_stage text, p_status text, p_receipt jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF p_stage NOT IN ('context','self_model_review','reflection','metacognition','fixture_skill','fixture_self_hypothesis','inference','candidate')
 OR (p_status NOT IN ('running','completed') AND NOT (p_stage='inference' AND p_status='failed') AND NOT (p_stage IN ('reflection','metacognition','candidate') AND p_status='skipped')) OR (p_stage='candidate' AND p_status<>'skipped') THEN RAISE EXCEPTION 'Invalid stage'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name LIKE 'cogcor_pseudo_daemon_v1:%' AND status='running' AND started_at>now()-interval '9 minutes') THEN RAISE EXCEPTION 'Run not running'; END IF;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,p_stage,p_status,1,CASE WHEN p_status='completed' THEN 1 ELSE 0 END,p_receipt,CASE WHEN p_status IN ('completed','failed','skipped') THEN now() END)
 ON CONFLICT(job_run_id,stage_name) DO UPDATE SET status=excluded.status,output_count=excluded.output_count,receipt=excluded.receipt,finished_at=excluded.finished_at;
IF p_stage='inference' AND p_status IN ('completed','failed') THEN INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES(CASE WHEN p_status='completed' THEN 'inference_completed' ELSE 'inference_failed' END,p_run,p_status); END IF;
END; $function$;

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
 error_summary=left(p_error,150),finished_at=now(),output_summary=jsonb_build_object('native_completed_stages',(SELECT count(*) FROM public.job_stages WHERE job_run_id=p_run AND status='completed'),'outcome_observed',false,'generated_stages',(SELECT coalesce(jsonb_agg(stage_name ORDER BY stage_name),'[]'::jsonb) FROM public.job_stages WHERE job_run_id=p_run AND stage_name IN ('reflection','metacognition','candidate') AND status='completed'),'skipped_stages',(SELECT coalesce(jsonb_agg(stage_name ORDER BY stage_name),'[]'::jsonb) FROM public.job_stages WHERE job_run_id=p_run AND status='skipped'),'learning_output',CASE WHEN p_status<>'completed' THEN 'failed' WHEN EXISTS(SELECT 1 FROM public.job_stages WHERE job_run_id=p_run AND stage_name IN ('reflection','metacognition','candidate') AND status='completed') THEN 'generated' ELSE 'no_learning_needed' END)
 WHERE id=p_run AND status='running';
 IF p_status='failed' AND EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name='cogcor_pseudo_daemon_v1:production') THEN
 UPDATE cogcor_daemon_private.control SET auto_enabled=false,enabled=false,inference_approved=false,auto_last_status='paused_after_failure' WHERE id;
 END IF;
 INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('job_finished',p_run,p_status);
 IF p_status='failed' THEN INSERT INTO cogcor_learning_private.audit(event_type,run_id,status) VALUES('failure_reason',p_run,CASE WHEN p_error ~ '^AI_(OUTPUT_[A-Z_]+|BINDING_FAILED|TIMEOUT)$' THEN p_error ELSE 'EXECUTION_FAILED' END); END IF;
END; $function$;

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
     AND EXISTS(SELECT 1 FROM public.job_stages i WHERE i.job_run_id=j.id AND i.stage_name='inference'
       AND i.status='completed' AND i.receipt->>'validation'='accepted'
       AND jsonb_typeof(i.receipt->'generated_fields')='array'
       AND NOT EXISTS(
         SELECT 1 FROM (VALUES ('reflection','reflection'),('self_model_question','metacognition'),('candidate','candidate')) AS expected(field,stage)
         WHERE NOT EXISTS(SELECT 1 FROM public.job_stages s WHERE s.job_run_id=j.id AND s.stage_name=expected.stage
           AND s.status=CASE WHEN (i.receipt->'generated_fields') ? expected.field THEN 'completed' ELSE 'skipped' END
           AND (s.status='completed' OR s.receipt->>'reason'='not_needed')))
       AND CASE WHEN (i.receipt->'generated_fields') ? 'candidate' THEN
         EXISTS(SELECT 1 FROM public.cognitive_proposals p WHERE p.job_run_id=j.id
           AND p.status='pending' AND p.rationale LIKE '%learning_candidate%'
           AND p.source_records @> jsonb_build_array(jsonb_build_object('table','cogcor_chat_bridge.moments','id',c.auto_moment_id::text)))
       ELSE NOT EXISTS(SELECT 1 FROM public.cognitive_proposals p WHERE p.job_run_id=j.id) END)) INTO verified;
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
$function$
;
