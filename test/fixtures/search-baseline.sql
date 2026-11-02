CREATE OR REPLACE FUNCTION cogcor_chat_bridge.recall_baseline(p_query text, p_limit integer DEFAULT 8)
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
