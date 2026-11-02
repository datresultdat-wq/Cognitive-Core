-- Operator-only adoption of an explicitly human-approved revision. No inference or scheduling.
BEGIN;
SET LOCAL lock_timeout='3s';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM cogcor_daemon_private.control WHERE enabled OR auto_enabled OR inference_approved OR manual_approval_id IS NOT NULL OR auto_approval_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.job_runs WHERE job_name='cogcor_pseudo_daemon_v1:production' AND status='running') THEN RAISE EXCEPTION 'registration_migration_requires_quiescence'; END IF;
END $$;
CREATE TABLE cogcor_learning_private.rule_revisions (
 candidate_id uuid PRIMARY KEY REFERENCES public.cognitive_proposals(id),
 revision integer NOT NULL DEFAULT 1 CHECK(revision=1),
 skill_id uuid UNIQUE NOT NULL REFERENCES public.skills(id),
 approval_event_id bigint NOT NULL REFERENCES cogcor_chat_bridge.moments(id),
 approval_ref text NOT NULL CHECK(length(approval_ref) BETWEEN 10 AND 300),
 original_candidate jsonb NOT NULL,
 source_snapshot jsonb NOT NULL,
 approval_snapshot jsonb NOT NULL,
 approved_rule jsonb NOT NULL,
 comparisons jsonb NOT NULL,
 change_reason text NOT NULL CHECK(length(change_reason) BETWEEN 10 AND 1000),
 registered_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE cogcor_learning_private.rule_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON cogcor_learning_private.rule_revisions FROM PUBLIC,anon,authenticated,service_role;
-- Append-only evidence: later changes require a separately reviewed revision mechanism.
CREATE FUNCTION cogcor_learning_private.reject_revision_mutation() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'immutable_rule_revision'; END $$;
REVOKE ALL ON FUNCTION cogcor_learning_private.reject_revision_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER immutable_rule_revision BEFORE UPDATE OR DELETE ON cogcor_learning_private.rule_revisions
FOR EACH ROW EXECUTE FUNCTION cogcor_learning_private.reject_revision_mutation();

CREATE FUNCTION public.cogcor_learning_review_v2(
 p_candidate uuid,p_approval_event bigint,p_approval_ref text,p_rule jsonb,p_comparisons jsonb,p_change_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE p public.cognitive_proposals; m cogcor_chat_bridge.moments; a cogcor_chat_bridge.moments;
 old cogcor_learning_private.rule_revisions; s uuid; k text; cmp jsonb; ids uuid[]; body text;
BEGIN
 PERFORM pg_advisory_xact_lock(31020261);
 SELECT * INTO old FROM cogcor_learning_private.rule_revisions WHERE candidate_id=p_candidate;
 IF FOUND THEN
  IF old.approval_event_id IS DISTINCT FROM p_approval_event OR old.approval_ref IS DISTINCT FROM p_approval_ref
   OR old.approved_rule IS DISTINCT FROM p_rule OR old.comparisons IS DISTINCT FROM p_comparisons
   OR old.change_reason IS DISTINCT FROM p_change_reason THEN RAISE EXCEPTION 'conflicting_registration_replay'; END IF;
  -- Replay returns existing state; never reactivates a held skill or overwrites an evaluated result.
  RETURN jsonb_build_object('skill_id',old.skill_id,'registered',false,'review_status',(SELECT state FROM cogcor_learning_private.reviews WHERE candidate_id=p_candidate),'effectiveness_verified',false);
 END IF;
 IF p_rule IS NULL OR jsonb_typeof(p_rule)<>'object' OR
  (SELECT count(*) FROM jsonb_object_keys(p_rule))<>5 THEN RAISE EXCEPTION 'invalid_rule'; END IF;
 FOREACH k IN ARRAY ARRAY['title','conditions','procedure','expected','exceptions'] LOOP
  IF jsonb_typeof(p_rule->k) IS DISTINCT FROM 'string' OR length(btrim(p_rule->>k)) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'invalid_rule_field'; END IF;
 END LOOP;
 IF length(p_rule->>'title')>120 OR p_approval_ref IS NULL OR length(p_approval_ref) NOT BETWEEN 10 AND 300
  OR p_change_reason IS NULL OR length(p_change_reason) NOT BETWEEN 10 AND 1000 THEN RAISE EXCEPTION 'invalid_review_metadata'; END IF;
 SELECT * INTO STRICT p FROM public.cognitive_proposals WHERE id=p_candidate FOR UPDATE;
 IF p.status<>'pending' OR p.proposal_type<>'orphan' OR p.rationale IS NULL OR p.rationale NOT LIKE '%learning_candidate%'
  OR NOT EXISTS(SELECT 1 FROM public.job_runs WHERE id=p.job_run_id AND job_name='cogcor_pseudo_daemon_v1:production' AND status='completed')
  OR EXISTS(SELECT 1 FROM cogcor_learning_private.reviews WHERE candidate_id=p.id) THEN RAISE EXCEPTION 'not_unreviewed_completed_candidate'; END IF;
 SELECT * INTO m FROM cogcor_chat_bridge.moments WHERE id=(p.source_records->0->>'id')::bigint
  AND p.source_records->0->>'table'='cogcor_chat_bridge.moments';
 IF NOT FOUND OR m.origin<>'chatgpt_yuna_normal' OR m.evidence_type NOT IN ('user_direct','observed_result')
  OR nullif(btrim(m.source_quote),'') IS NULL THEN RAISE EXCEPTION 'candidate_evidence'; END IF;
 SELECT * INTO a FROM cogcor_chat_bridge.moments WHERE id=p_approval_event;
 IF NOT FOUND OR a.origin<>'codex_user_approval' OR a.evidence_type<>'user_direct' OR a.recorded_at<p.created_at
  OR nullif(btrim(a.source_quote),'') IS NULL THEN RAISE EXCEPTION 'explicit_human_approval_required'; END IF;
 -- The operator records the real user's approval; AI candidates cannot supply this authority.
 -- Every approved field must appear verbatim in that approval evidence (not only a vague yes).
 FOREACH k IN ARRAY ARRAY['title','conditions','procedure','expected','exceptions'] LOOP
  IF strpos(a.source_quote,p_rule->>k)=0 THEN RAISE EXCEPTION 'rule_not_in_approval'; END IF;
 END LOOP;
 IF strpos(a.source_quote,'正式採用することを承認します')=0 THEN RAISE EXCEPTION 'adoption_not_explicit'; END IF;
 -- Freeze active skills while checking the operator's complete, current comparison snapshot.
 LOCK TABLE public.skills IN SHARE ROW EXCLUSIVE MODE;
 IF p_comparisons IS NULL OR jsonb_typeof(p_comparisons)<>'array' THEN RAISE EXCEPTION 'compare_all_active_skills'; END IF;
 ids:='{}';
 FOR cmp IN SELECT value FROM jsonb_array_elements(p_comparisons) LOOP
  IF cmp->>'relationship' IS NULL OR cmp->>'relationship' NOT IN ('compatible','overlap_distinct')
   OR length(btrim(coalesce(cmp->>'reason',''))) NOT BETWEEN 10 AND 1000 THEN RAISE EXCEPTION 'unresolved_skill_conflict'; END IF;
  IF (cmp->>'skill_id')::uuid=ANY(ids) THEN RAISE EXCEPTION 'duplicate_comparison'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.skills x WHERE x.id=(cmp->>'skill_id')::uuid AND x.status='active'
    AND md5(to_jsonb(x)::text)=cmp->>'signature') THEN RAISE EXCEPTION 'stale_skill_comparison'; END IF;
  ids:=array_append(ids,(cmp->>'skill_id')::uuid);
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.skills WHERE status='active' AND NOT(id=ANY(ids))) THEN RAISE EXCEPTION 'compare_all_active_skills'; END IF;
 body:=(p_rule->>'procedure')||E'\n例外：'||(p_rule->>'exceptions');
 IF EXISTS(SELECT 1 FROM public.skills WHERE status='active' AND
  (cogcor_learning_private.normalized(approach)=cogcor_learning_private.normalized(body)
   OR cogcor_learning_private.normalized(skill_name)=cogcor_learning_private.normalized(p_rule->>'title'))) THEN RAISE EXCEPTION 'duplicate_skill'; END IF;
 INSERT INTO public.skills(skill_name,description,approach,trigger_context,source,tags)
 VALUES(p_rule->>'title',p_rule->>'expected',body,p_rule->>'conditions','cogcor_reviewed_candidate','["reviewed_procedure","human_approved_revision"]') RETURNING id INTO s;
 INSERT INTO cogcor_learning_private.reviews(candidate_id,source_event_id,review_event_id,skill_id,state,conditions,expected_improvement,comparison_notes,compared_skill_ids)
 VALUES(p.id,m.id,a.id,s,'approved',p_rule->>'conditions',p_rule->>'expected','Full per-skill comparison and human approval are preserved in rule_revisions.',ids);
 INSERT INTO cogcor_learning_private.rule_revisions(candidate_id,skill_id,approval_event_id,approval_ref,original_candidate,source_snapshot,approval_snapshot,approved_rule,comparisons,change_reason)
 VALUES(p.id,s,a.id,p_approval_ref,to_jsonb(p),to_jsonb(m),to_jsonb(a),p_rule,p_comparisons,p_change_reason);
 UPDATE public.cognitive_proposals SET status='accepted',accepted_content=body,accepted_record_table='skills',accepted_record_id=s,resolved_at=now() WHERE id=p.id;
 INSERT INTO cogcor_learning_private.audit(event_type,event_id,ref_id,status) VALUES('skill_adopted',m.id,s,'human_approved_revision_unverified');
 RETURN jsonb_build_object('skill_id',s,'registered',true,'review_status','approved','effectiveness_verified',false);
END $$;
REVOKE ALL ON FUNCTION public.cogcor_learning_review_v2(uuid,bigint,text,jsonb,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
-- Old review RPC cannot rewrite the provenance/terms of a v2 registration.
CREATE FUNCTION cogcor_learning_private.protect_revision_review() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF OLD.comparison_notes='Full per-skill comparison and human approval are preserved in rule_revisions.' THEN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_revision_review'; END IF;
  IF (to_jsonb(NEW)-'state'-'reviewed_at') IS DISTINCT FROM (to_jsonb(OLD)-'state'-'reviewed_at') THEN RAISE EXCEPTION 'immutable_revision_review'; END IF;
  IF NEW.state='approved' AND OLD.state<>'approved' THEN RAISE EXCEPTION 'reactivation_requires_new_review'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION cogcor_learning_private.protect_revision_review() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER protect_revision_review BEFORE UPDATE OR DELETE ON cogcor_learning_private.reviews
FOR EACH ROW EXECUTE FUNCTION cogcor_learning_private.protect_revision_review();
COMMIT;
