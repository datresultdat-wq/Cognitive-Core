-- New project only. No inference is enabled by this migration.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
ALTER TABLE cogcor_daemon_private.control
 ADD COLUMN manual_approval_id uuid,
 ADD COLUMN manual_moment_id bigint,
 ADD COLUMN manual_approval_expires_at timestamptz;
-- Replace arity atomically; older named-argument callers use the NULL default.
DROP FUNCTION public.cogcor_daemon_claim_v1(timestamptz,boolean);
CREATE FUNCTION public.cogcor_daemon_claim_v1(p_tick timestamptz,p_test_only boolean DEFAULT false,p_approval_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
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
END; $body$;

REVOKE ALL ON FUNCTION public.cogcor_daemon_claim_v1(timestamptz,boolean,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_daemon_claim_v1(timestamptz,boolean,uuid) TO service_role;

-- Only outcomes linked to an actual later observation and completed production candidate.
CREATE FUNCTION public.cogcor_daemon_outcomes_v1(p_hours integer DEFAULT 24,p_limit integer DEFAULT 3)
RETURNS TABLE(outcome_id uuid,candidate_id uuid,candidate text,score real,evidence_ref text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $body$
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
$body$;
REVOKE ALL ON FUNCTION public.cogcor_daemon_outcomes_v1(integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_daemon_outcomes_v1(integer,integer) TO service_role;
COMMIT;
