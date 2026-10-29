-- NEW wllbmvnimempkqzgshsi only. Apply before the Worker context change.
-- No table rewrite, no RLS changes, no client-role access, no write grants.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
DO $guard$
BEGIN
 IF to_regprocedure('public.cogcor_processing_moments_v1(integer,integer)') IS NOT NULL THEN
  RAISE EXCEPTION 'Adapter already exists: inspect definition before reapplying';
 END IF;
 IF (SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE oid='cogcor_chat_bridge.remember(text,text,text,text,text)'::regprocedure)<>'f293cfdb3a635816ec342eda5a93f008' THEN
  RAISE EXCEPTION 'Concurrent bridge change: re-audit';
 END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='cogcor_chat_bridge.moments'::regclass) THEN
  RAISE EXCEPTION 'Moments RLS must remain enabled';
 END IF;
END $guard$;
CREATE FUNCTION public.cogcor_processing_moments_v1(p_hours integer DEFAULT 24,p_limit integer DEFAULT 10)
RETURNS TABLE(id bigint,recorded_at timestamptz,event_date date,memory_kind text,evidence_type text,memory_content text,source_quote text,origin text,source_ref text,source_record jsonb,verification text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $body$
 SELECT m.id,m.recorded_at,m.event_date,m.memory_kind,m.evidence_type,m.memory_content,m.source_quote,m.origin,
 'cogcor_chat_bridge:moments:'||m.id,
 jsonb_build_object('table','cogcor_chat_bridge.moments','id',m.id::text,'role','supporting','evidence_type',m.evidence_type),
 'caller_attributed_not_independently_verified'::text
 FROM cogcor_chat_bridge.moments m
 WHERE m.origin='chatgpt_yuna_normal'
 AND m.recorded_at>=now()-make_interval(hours=>greatest(1,least(coalesce(p_hours,24),72)))
 ORDER BY m.recorded_at DESC,m.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,10),20));
$body$;
REVOKE ALL ON FUNCTION public.cogcor_processing_moments_v1(integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.cogcor_processing_moments_v1(integer,integer) TO service_role;
GRANT USAGE ON SCHEMA cogcor_chat_bridge TO service_role;
GRANT SELECT ON cogcor_chat_bridge.moments TO service_role;
-- remember/recall remain postgres-only. No new direct write path is granted.
COMMIT;
