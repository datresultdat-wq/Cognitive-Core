-- NEW CogCor v2 only: automatic inference is DISARMED by default.
-- Deploy code and regression tests BEFORE explicitly arming the controller.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='25s';
ALTER TABLE cogcor_daemon_private.control
 ADD COLUMN IF NOT EXISTS auto_enabled boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS auto_started_at timestamptz,
 ADD COLUMN IF NOT EXISTS auto_approval_id uuid,
 ADD COLUMN IF NOT EXISTS auto_moment_id bigint,
 ADD COLUMN IF NOT EXISTS auto_reserved_at timestamptz,
 ADD COLUMN IF NOT EXISTS auto_last_status text;

-- Service-only, bounded cron reservation, reusing the existing one-event approval.
CREATE OR REPLACE FUNCTION public.cogcor_daemon_auto_reserve_v1(p_tick timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
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
$body$;

-- Success must be backed by a completed production run; anything else disarms.
CREATE OR REPLACE FUNCTION public.cogcor_daemon_auto_finalize_v1(
 p_approval_id uuid, p_success boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
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
$body$;

REVOKE ALL ON FUNCTION public.cogcor_daemon_auto_reserve_v1(timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.cogcor_daemon_auto_finalize_v1(uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_daemon_auto_reserve_v1(timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.cogcor_daemon_auto_finalize_v1(uuid,boolean) TO service_role;
-- No changes to existing RLS/Essence/persona or old YUNA projects.
COMMIT;
