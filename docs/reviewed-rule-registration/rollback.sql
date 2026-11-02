-- Stop new v2 registrations without deleting candidates, skills, approval evidence or history.
-- Does not change automation, Cron, RLS, secrets, or existing review/scoring APIs.
BEGIN;
SET LOCAL lock_timeout='3s';
DROP FUNCTION public.cogcor_learning_review_v2(uuid,bigint,text,jsonb,jsonb,text);
COMMIT;
-- If a registered rule itself is faulty, separately hold ONLY its reviewed candidate_id
-- after inspecting applications/outcomes. Keep rule_revisions and original records intact.
-- UPDATE cogcor_learning_private.reviews SET state='held' WHERE candidate_id = <reviewed UUID>;
