import assert from 'node:assert/strict';
export async function testAllLearning({q,test,reject,moment,candidate,uuid}){
 const capture=(message,content='SYNTHETIC correction: use source evidence',context='real')=>q("SELECT public.cogcor_learning_capture_v1('synthetic-chat',$1,now(),'conversation_event',$2,$2,'user_direct',$3) r",[message,content,context]);
 await test('capture has stable source/time; replay cannot create a duplicate or silently rewrite text',async()=>{
  const a=(await capture('message-1'))[0].r,b=(await capture('message-1'))[0].r,c=(await capture('message-2'))[0].r;
  assert.equal(a.moment_id,b.moment_id);assert.equal(a.moment_id,c.moment_id);assert.equal(b.stored,false);assert.equal(c.stored,false);
  await reject("SELECT public.cogcor_learning_capture_v1('synthetic-chat','message-1',now(),'conversation_event','changed','changed','user_direct','real')",[],/capture_replay_conflict/);
  assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.capture_receipts'))[0].n,2);
 });
 await test('all existing kinds/evidence remain labeled when eligible; no daily cap or inference in tests',async()=>{
  await q("UPDATE cogcor_daemon_private.control SET auto_enabled=true,auto_started_at=now()-interval '2 hours'");
  const m=await moment('assistant_interpretation','SYNTHETIC interpretation, not a fact');
  await q("UPDATE cogcor_chat_bridge.moments SET memory_kind='user_fact',source_quote=NULL WHERE id=$1",[m]);
  const grant=(await q('SELECT public.cogcor_daemon_auto_reserve_v1(now()) r'))[0].r;
  assert.equal(grant.status,'approved');const c=(await q('SELECT public.cogcor_daemon_claim_v1(now(),false,$1) r',[grant.approval_id]))[0].r;
  assert.equal(c.event.evidence_type,'assistant_interpretation');assert.equal(c.event.memory_kind,'user_fact');
 });
 await test('pending source-bearing learning can be retrieved/used without formal approval; retrieval is not use',async()=>{
  const c=await candidate();const r=(await q("SELECT public.cogcor_learning_provisional_context_v1('領収書') r"))[0].r;
  assert.ok(r.provisional_candidates.some(p=>p.candidate_id===c.p));assert.equal(r.retrieval_is_application,false);
  const id=uuid(),sql="SELECT public.cogcor_learning_provisional_apply_v1($1,$2,'synthetic-chat',$3,$4) r";
  await q(sql,[id,c.p,'retrieved',null]);assert.equal((await q('SELECT stage FROM cogcor_learning_private.provisional_applications WHERE id=$1',[id]))[0].stage,'retrieved');
  await reject(sql,[id,c.p,'applied','response-1'],/invalid_transition/);
  await q(sql,[id,c.p,'selected','Useful evidence for this synthetic situation']);await q(sql,[id,c.p,'applied','response-1']);await q(sql,[id,c.p,'applied','response-1']);
  assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.provisional_applications'))[0].n,1);
  assert.equal((await q('SELECT count(*)::int n FROM public.skills'))[0].n,0);
  const obs=await moment('observed_result','SYNTHETIC observed benefit','0 seconds');
  await q("SELECT public.cogcor_learning_provisional_apply_v1($1,$2,'synthetic-chat','outcome_observed',NULL,$3)",[id,c.p,obs]);
  await q("SELECT public.cogcor_learning_provisional_apply_v1($1,$2,'synthetic-chat','scored','SYNTHETIC',NULL,'uncertain')",[id,c.p]);
  assert.equal((await q('SELECT evaluation FROM cogcor_learning_private.provisional_applications WHERE id=$1',[id]))[0].evaluation,'uncertain');
 });
 await test('direct current correction holds old hypothesis without deleting it; next recall returns correction',async()=>{
  const c=await candidate(),id=uuid();const event=await moment('user_direct','SYNTHETIC 領収書 correction: the earlier hypothesis is not applicable','0 seconds');
  await q("SELECT public.cogcor_learning_provisional_apply_v1($1,$2,'chat','retrieved')",[id,c.p]);
  await q('SELECT public.cogcor_learning_correct_v1($1,$2)',[c.p,event]);await q('SELECT public.cogcor_learning_correct_v1($1,$2)',[c.p,event]);
  const result=(await q("SELECT public.cogcor_learning_provisional_context_v1('領収書') r"))[0].r;
  assert.ok(!result.provisional_candidates.some(p=>p.candidate_id===c.p));assert.ok(result.corrections.some(p=>p.candidate_id===c.p));assert.equal(result.unreviewed_candidates,undefined);
  await reject("SELECT public.cogcor_learning_provisional_apply_v1($1,$2,'chat','selected','ignore the correction')",[id,c.p],/provisional_not_available/);
  assert.equal((await q('SELECT status FROM public.cognitive_proposals WHERE id=$1',[c.p]))[0].status,'pending');
  assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.provisional_corrections'))[0].n,1);
 });
 await test('fiction/hypotheses cannot provide real corrections or observed success; public access stays closed',async()=>{
  const c=await candidate(),e=(await capture('fiction-1','SYNTHETIC fictional correction','fiction'))[0].r.moment_id;
  await reject('SELECT public.cogcor_learning_correct_v1($1,$2)',[c.p,e],/direct_current_correction_required/);
  assert.equal((await q("SELECT has_function_privilege('anon','public.cogcor_learning_capture_v1(text,text,timestamptz,text,text,text,text,text)','EXECUTE') ok"))[0].ok,false);
  assert.equal((await q("SELECT has_function_privilege('service_role','public.cogcor_learning_review_v2(uuid,bigint,text,jsonb,jsonb,text)','EXECUTE') ok"))[0].ok,false);
 });
}
