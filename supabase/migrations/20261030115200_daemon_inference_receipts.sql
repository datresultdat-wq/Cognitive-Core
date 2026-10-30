-- New CogCor v2 only. Add inference receipts without changing grants/RLS/control.
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION public.cogcor_daemon_stage_v1(p_run uuid,p_stage text,p_status text,p_receipt jsonb) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $body$
BEGIN
 IF p_stage NOT IN ('context','self_model_review','reflection','metacognition','fixture_skill','fixture_self_hypothesis','inference')
 OR (p_status NOT IN ('running','completed') AND NOT (p_stage='inference' AND p_status='failed')) THEN RAISE EXCEPTION 'Invalid stage'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p_run AND job_name LIKE 'cogcor_pseudo_daemon_v1:%' AND status='running') THEN RAISE EXCEPTION 'Run not running'; END IF;
 INSERT INTO public.job_stages(job_run_id,stage_name,status,input_count,output_count,receipt,finished_at)
 VALUES(p_run,p_stage,p_status,1,CASE WHEN p_status='completed' THEN 1 ELSE 0 END,p_receipt,CASE WHEN p_status IN ('completed','failed') THEN now() END)
 ON CONFLICT(job_run_id,stage_name) DO UPDATE SET status=excluded.status,output_count=excluded.output_count,receipt=excluded.receipt,finished_at=excluded.finished_at;
END; $body$;
COMMIT;
