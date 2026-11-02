import assert from 'node:assert/strict';
export async function testReviewedRule({q,test,reject,moment,candidate,transition,uuid}) {
 const rule={title:'領収書の根拠照合手順',conditions:'領収書の番号について回答するとき',procedure:'原文を確認してから番号を答える。未確認なら不明と答える。',expected:'裏付けのない番号の断定を減らす',exceptions:'原文がない場合には番号を推測しない'};
 const ref='synthetic:approval:operator-fixture';
 const reason='Synthetic revision turns an abstract candidate into an explicit procedure.';
 const sql='SELECT public.cogcor_learning_review_v2($1,$2,$3,$4::jsonb,$5::jsonb,$6) r';
 const comparisons=async()=> (await q(`SELECT coalesce(jsonb_agg(jsonb_build_object('skill_id',s.id,'signature',md5(to_jsonb(s)::text),'relationship','compatible','reason','Distinct synthetic procedure; no conflict in fixture')),'[]') c FROM public.skills s WHERE status='active'`))[0].c;
 const fixture=async()=>{
  const c=await candidate();const a=await moment('user_direct','SYNTHETIC operator-recorded approval','0 seconds');
  await q(`UPDATE cogcor_chat_bridge.moments SET origin='codex_user_approval',source_quote=$2 WHERE id=$1`,[a,'正式採用することを承認します\n'+Object.values(rule).join('\n')]);
  return {...c,a,args:[c.p,a,ref,JSON.stringify(rule),JSON.stringify(await comparisons()),reason]};
 };
 await test('revised rule preserves original, source, real approval origin and exceptions; replay is idempotent',async()=>{
  const c=await fixture();const before=(await q('SELECT to_jsonb(p) p FROM public.cognitive_proposals p WHERE id=$1',[c.p]))[0].p;
  const r=(await q(sql,c.args))[0].r;
  assert.equal(r.effectiveness_verified,false);assert.equal(r.registered,true);
  const rev=(await q('SELECT * FROM cogcor_learning_private.rule_revisions WHERE candidate_id=$1',[c.p]))[0];
  assert.deepEqual(rev.original_candidate,before);assert.deepEqual(rev.approved_rule,rule);assert.equal(rev.approval_snapshot.origin,'codex_user_approval');
  const skill=(await q('SELECT approach,times_used,times_succeeded FROM public.skills WHERE id=$1',[r.skill_id]))[0];
  assert.equal(skill.approach,rule.procedure+'\n例外：'+rule.exceptions);assert.equal(skill.times_used,0);assert.equal(skill.times_succeeded,0);
  assert.equal((await q(sql,c.args))[0].r.registered,false);
  assert.equal((await q('SELECT count(*)::int n FROM public.skills'))[0].n,1);
  const context=(await q("SELECT public.cogcor_learning_context_v1('領収書') c"))[0].c;
  assert.equal(context.reviewed_skills[0].skill_id,r.skill_id);
 });
 await test('wrong approval origin, missing verbatim terms, summary source and replay changes fail closed',async()=>{
  const c=await fixture();await q("UPDATE cogcor_chat_bridge.moments SET origin='chatgpt_yuna_normal' WHERE id=$1",[c.a]);
  await reject(sql,c.args,/explicit_human_approval_required/);
  await q("UPDATE cogcor_chat_bridge.moments SET origin='codex_user_approval' WHERE id=$1",[c.a]);
  const changed=[...c.args];changed[3]=JSON.stringify({...rule,procedure:'This procedure was not approved by the user'});
  await reject(sql,changed,/rule_not_in_approval/);
  await q("UPDATE cogcor_chat_bridge.moments SET evidence_type='conversation_summary' WHERE id=$1",[c.m]);
  await reject(sql,c.args,/candidate_evidence/);await q("UPDATE cogcor_chat_bridge.moments SET evidence_type='user_direct' WHERE id=$1",[c.m]);
  await q(sql,c.args);await reject(sql,changed,/conflicting_registration_replay/);
 });
 await test('all active skills need fresh comparisons; unresolved conflicts and exact duplicates block adoption',async()=>{
  const c=await fixture();const id=(await q("INSERT INTO public.skills(skill_name,description,approach,status) VALUES('Other synthetic rule','Synthetic description','Other synthetic procedure','active') RETURNING id"))[0].id;
  await reject(sql,c.args,/compare_all_active_skills/);c.args[4]=JSON.stringify(await comparisons());
  await q("UPDATE public.skills SET approach='Changed after review' WHERE id=$1",[id]);await reject(sql,c.args,/stale_skill_comparison/);
  const cmp=await comparisons();c.args[4]=JSON.stringify(cmp.map(x=>({...x,relationship:'conflict'})));await reject(sql,c.args,/unresolved_skill_conflict/);
  await q('UPDATE public.skills SET skill_name=$2 WHERE id=$1',[id,rule.title]);c.args[4]=JSON.stringify(await comparisons());await reject(sql,c.args,/duplicate_skill/);
 });
 await test('unprivileged callers cannot adopt or read approval snapshots; existing RLS is not widened',async()=>{
  for(const role of ['anon','authenticated','service_role']) {
   assert.equal((await q("SELECT has_function_privilege($1,'public.cogcor_learning_review_v2(uuid,bigint,text,jsonb,jsonb,text)','EXECUTE') p",[role]))[0].p,false);
   assert.equal((await q("SELECT has_table_privilege($1,'cogcor_learning_private.rule_revisions','SELECT') p",[role]))[0].p,false);
  }
 });
 await test('revision history and approved review terms cannot be overwritten',async()=>{
  const c=await fixture();await q(sql,c.args);
  await reject('UPDATE cogcor_learning_private.rule_revisions SET change_reason=$2 WHERE candidate_id=$1',[c.p,'overwrite evidence'],/immutable_rule_revision/);
  await reject('DELETE FROM cogcor_learning_private.rule_revisions WHERE candidate_id=$1',[c.p],/immutable_rule_revision/);
  await reject("UPDATE cogcor_learning_private.reviews SET conditions='different condition' WHERE candidate_id=$1",[c.p],/immutable_revision_review/);
 });
 await test('revised skill negative outcome pauses usage; registration replay cannot reactivate it',async()=>{
  const c=await fixture(),r=(await q(sql,c.args))[0].r,id=uuid();
  await transition(id,r.skill_id,'retrieved');await transition(id,r.skill_id,'selected','Synthetic applicable condition');await transition(id,r.skill_id,'applied','synthetic-reply');
  const obs=await moment('user_direct','SYNTHETIC observed failure','1 second');await transition(id,r.skill_id,'outcome_observed',null,obs);
  await q('SELECT public.cogcor_learning_score_v1($1,false)',[id]);assert.equal((await q(sql,c.args))[0].r.review_status,'held');
  await reject("UPDATE cogcor_learning_private.reviews SET state='approved' WHERE candidate_id=$1",[c.p],/reactivation_requires_new_review/);
 });
}
export async function testConcurrentRegistration({clients,q,moment,candidate}) {
 const c=await candidate(),a=await moment('user_direct','SYNTHETIC concurrent approval','0 seconds');
 await q("UPDATE cogcor_chat_bridge.moments SET memory_content='SYNTHETIC concurrent-only correction' WHERE id=$1",[c.m]);
 const rule={title:'Concurrent synthetic procedure',conditions:'Only concurrent synthetic fixtures',procedure:'Inspect the synthetic receipt before replying',expected:'Reduce synthetic unsupported replies',exceptions:'Do not infer a missing synthetic receipt'};
 await q("UPDATE cogcor_chat_bridge.moments SET origin='codex_user_approval',source_quote=$2 WHERE id=$1",[a,'正式採用することを承認します\n'+Object.values(rule).join('\n')]);
 const cmp=(await q(`SELECT coalesce(jsonb_agg(jsonb_build_object('skill_id',s.id,'signature',md5(to_jsonb(s)::text),'relationship','compatible','reason','Different synthetic procedure with no conflict')),'[]') c FROM public.skills s WHERE status='active'`))[0].c;
 const args=[c.p,a,'synthetic:concurrent:approval',JSON.stringify(rule),JSON.stringify(cmp),'Synthetic concurrent registration of one explicit revision'];
 const rs=await Promise.all(clients.map(x=>x.query('SELECT public.cogcor_learning_review_v2($1,$2,$3,$4::jsonb,$5::jsonb,$6) r',args)));
 assert.equal(rs.filter(x=>x.rows[0].r.registered).length,1);assert.equal(new Set(rs.map(x=>x.rows[0].r.skill_id)).size,1);
 assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.rule_revisions WHERE candidate_id=$1',[c.p]))[0].n,1);
}
