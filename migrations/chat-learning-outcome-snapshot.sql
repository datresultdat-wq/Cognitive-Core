-- Already applied to new Supabase wllbmvnimempkqzgshsi before this commit.
-- Snapshot of pg_get_functiondef; do NOT reapply to the live project.
BEGIN;
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
$function$

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
$function$

REVOKE ALL ON FUNCTION cogcor_chat_bridge.recall(text,integer), cogcor_chat_bridge.record_learning_outcome(uuid,bigint,boolean) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION cogcor_chat_bridge.recall(text,integer), cogcor_chat_bridge.record_learning_outcome(uuid,bigint,boolean) TO postgres;
COMMIT;
