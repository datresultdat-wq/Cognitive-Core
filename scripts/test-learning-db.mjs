// Local-only PostgreSQL WASM integration harness. Never connects to Supabase.
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
const nativeSocket=process.env.COGCOR_NATIVE_SOCKET;
let Client;
let db;
if(nativeSocket){
 if(!/^\/tmp\/cogcor-native-run-[A-Za-z0-9]+$/.test(nativeSocket))throw new Error('Only isolated local fixture socket allowed');
 const pg=await import(pathToFileURL(process.env.COGCOR_PG_MODULE));Client=pg.default.Client;
 const client=new Client({host:nativeSocket,port:55439,user:'postgres',database:'postgres'});await client.connect();
 db={exec:sql=>client.query(sql),query:(sql,args)=>client.query(sql,args),close:()=>client.end()};
} else {
 const harness=process.env.COGCOR_LOCAL_PGLITE || fileURLToPath(new URL('./local-db/node_modules/@electric-sql/pglite',import.meta.url));
 const {PGlite}=await import(pathToFileURL(resolve(harness,'dist/index.js')));
 const {pg_trgm}=await import(pathToFileURL(resolve(harness,'dist/contrib/pg_trgm.js')));
 db=new PGlite({extensions:{pg_trgm}});
}
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
try {
 await db.exec(read('test/fixtures/local-learning-base.sql'));
 await db.exec(read('test/fixtures/local-learning-constraints.sql'));
 await db.exec(`CREATE TABLE public.custom_memories(content text,status text,source text);
 CREATE TABLE public.inside_jokes(content text,status text,source text);
 CREATE TABLE public.patterns(content text,description text,status text,source text);
 CREATE TABLE public.essence(content text,pinned boolean,source text);
 CREATE TABLE public.people(name text,content text,source text);`);
 await db.exec(read('supabase/migrations/20261102011543_continuous_learning_contract.sql'));
 await db.exec(read('test/fixtures/search-baseline.sql'));
 console.log('Local migration applied; no remote connections.');
} catch(e) { console.error('LOCAL MIGRATION FAILED:',e.message,e.position,e.where);process.exitCode=1;await db.close();process.exit(1); }
let count=0;
const q=async(sql,args=[]) => (await db.query(sql,args)).rows;
const test=async(name,fn)=>{await db.exec('BEGIN');try{await fn();count++;console.log('PASS',name);}finally{await db.exec('ROLLBACK');}};
const reject=async(sql,args,pattern)=>{
 await db.exec('SAVEPOINT expected_failure');
 try {await assert.rejects(()=>q(sql,args),pattern);}finally{await db.exec('ROLLBACK TO SAVEPOINT expected_failure; RELEASE SAVEPOINT expected_failure');}
};
const moment=async(type='user_direct',content='Synthetic direct correction: check the original receipt before answering',offset='-1 hour')=>{
 return (await q(`INSERT INTO cogcor_chat_bridge.moments(memory_kind,evidence_type,memory_content,source_quote,recorded_at) VALUES('conversation_event',$1,$2,'SYNTHETIC QUOTE, NOT PERSONAL DATA',now()+$3::interval) RETURNING id`,[type,content,offset]))[0].id;
};
const candidate=async()=>{
 const m=await moment();const j=(await q(`INSERT INTO public.job_runs(job_name,status,started_at,finished_at) VALUES('cogcor_pseudo_daemon_v1:production','completed',now()-interval '30 minutes',now()-interval '29 minutes') RETURNING id`))[0].id;
 const p=(await q(`INSERT INTO public.cognitive_proposals(proposal_type,proposed_content,rationale,source_records,job_run_id,created_at) VALUES('orphan','領収書の原文を確認する','learning_candidate',jsonb_build_array(jsonb_build_object('table','cogcor_chat_bridge.moments','id',$1::text)),$2,now()-interval '20 minutes') RETURNING id`,[String(m),j]))[0].id;
 return {m,j,p};
};
const adopt=async()=>{
 const c=await candidate(),review=await moment('user_direct','SYNTHETIC human approval of specified procedure','-10 minutes');
 const s=(await q(`SELECT public.cogcor_learning_review_v1($1,$2,'approved','領収書を確認するときのみ','根拠なしの番号回答を減らす','Compared every active skill; no conflict found in synthetic fixture','{}') AS r`,[c.p,review]))[0].r.skill_id;
 return {...c,s};
};
const transition=(id,s,stage,evidence=null,observation=null)=>q(`SELECT public.cogcor_learning_application_v1($1,$2,'synthetic-chat',$3,$4,$5) r`,[id,s,stage,evidence,observation]);
const uuid=()=>crypto.randomUUID();
try {
 await test('defaults disarmed; expired/unapproved budget refuses work',async()=>{
  assert.equal((await q('SELECT public.cogcor_daemon_budget_status_v1() s'))[0].s,'budget_unapproved');
  assert.equal((await q('SELECT auto_enabled FROM cogcor_daemon_private.control'))[0].auto_enabled,false);
 });
 await test('summary cannot be adopted as direct evidence',async()=>{
  const c=await candidate();await q(`UPDATE cogcor_chat_bridge.moments SET evidence_type='conversation_summary' WHERE id=$1`,[c.m]);
  const review=await moment();await reject(`SELECT public.cogcor_learning_review_v1($1,$2,'approved','conditions','expected result','comparison completed','{}')`,[c.p,review],/candidate_evidence/);
 });
 await test('pending candidate cannot become an application',async()=>{
  const c=await candidate();await reject(`SELECT public.cogcor_learning_application_v1($1,$2,'chat','retrieved')`,[uuid(),uuid()],/skill_not_reviewed_active/);
  assert.equal((await q('SELECT count(*)::int n FROM public.skills'))[0].n,0);
 });
 await test('reviewed adoption is idempotent; retrieval is not use; ordered evidence transitions',async()=>{
  const c=await adopt(),id=uuid();await transition(id,c.s,'retrieved');await transition(id,c.s,'retrieved');
  assert.equal((await q('SELECT times_used FROM public.skills WHERE id=$1',[c.s]))[0].times_used,0);
  await reject(`SELECT public.cogcor_learning_application_v1($1,$2,'synthetic-chat','applied','response-id')`,[id,c.s],/invalid_transition/);
  await transition(id,c.s,'selected','Current question asks for receipt grounding');await transition(id,c.s,'applied','synthetic-response-1');await transition(id,c.s,'applied','synthetic-response-1');
  assert.equal((await q('SELECT times_used FROM public.skills WHERE id=$1',[c.s]))[0].times_used,1);
  await reject('SELECT public.cogcor_learning_score_v1($1,true)',[id],/observation_before_score/);
  const obs=await moment('observed_result','SYNTHETIC later human report: the quoted answer resolved the mistake','0 seconds');
  await transition(id,c.s,'outcome_observed',null,obs);
  await q('SELECT public.cogcor_learning_score_v1($1,true)',[id]);await q('SELECT public.cogcor_learning_score_v1($1,true)',[id]);
  await reject('SELECT public.cogcor_learning_score_v1($1,false)',[id],/conflicting_score/);
  assert.deepEqual((await q('SELECT times_used,times_succeeded,times_failed FROM public.skills WHERE id=$1',[c.s]))[0],{times_used:1,times_succeeded:1,times_failed:0});
  assert.equal((await q('SELECT count(*)::int n FROM public.outcome_scores'))[0].n,1);
  assert.equal((await q(`SELECT count(*)::int n FROM public.cogcor_daemon_related_outcomes_v1('領収書')`))[0].n,1);
 });
 await test('negative result pauses procedure; does not delete history or infer improvement',async()=>{
  const c=await adopt(),id=uuid();await transition(id,c.s,'retrieved');await transition(id,c.s,'selected','Synthetic relevant situation');await transition(id,c.s,'applied','response-2');
  const obs=await moment('user_direct','SYNTHETIC later report: procedure did not help','0 seconds');await transition(id,c.s,'outcome_observed',null,obs);await q('SELECT public.cogcor_learning_score_v1($1,false)',[id]);
  assert.equal((await q('SELECT state FROM cogcor_learning_private.reviews WHERE skill_id=$1',[c.s]))[0].state,'held');
  assert.equal((await q(`SELECT public.cogcor_learning_context_v1('領収書') r`))[0].r.reviewed_skills.length,0);
 });
 await test('service role cannot self-approve or self-score; public has no new access',async()=>{
  assert.equal((await q(`SELECT has_function_privilege('service_role','public.cogcor_learning_score_v1(uuid,boolean)','EXECUTE') p`))[0].p,false);
  assert.equal((await q(`SELECT has_function_privilege('service_role','public.cogcor_learning_review_v1(uuid,bigint,text,text,text,text,uuid[])','EXECUTE') p`))[0].p,false);
  assert.equal((await q(`SELECT has_function_privilege('anon','public.cogcor_learning_context_v1(text,integer)','EXECUTE') p`))[0].p,false);
 });
 await test('rolling call and cost budgets are enforced consistently before reserve and claim',async()=>{
  await q(`UPDATE cogcor_daemon_private.control SET auto_enabled=true,auto_started_at=now()-interval '2 hours',budget_approved_until=now()+interval '1 hour',max_calls_hour=2,max_calls_24h=3,cost_per_call_ceiling_usd=0.01,max_cost_usd_24h=0.02`);
  await moment();
  const reserve=(await q('SELECT public.cogcor_daemon_auto_reserve_v1(now()) r'))[0].r;assert.equal(reserve.status,'approved');
  assert.equal((await q('SELECT public.cogcor_daemon_auto_reserve_v1(now()) r'))[0].r.status,'duplicate_tick');
  const claim=(await q('SELECT public.cogcor_daemon_claim_v1(now(),false,$1) r',[reserve.approval_id]))[0].r;
  assert.equal(claim.status,'claimed');
  assert.equal((await q('SELECT trigger_source FROM public.job_runs WHERE id=$1',[claim.run_id]))[0].trigger_source,'automatic_approved');
  assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.call_reservations'))[0].n,1);
  assert.notEqual((await q('SELECT public.cogcor_daemon_claim_v1(now(),false,$1) r',[reserve.approval_id]))[0].r.status,'claimed');
  await q(`SELECT public.cogcor_daemon_finish_v1($1,'failed','SYNTHETIC_API_ERROR',true)`,[claim.run_id]);
  assert.equal((await q('SELECT status FROM cogcor_daemon_private.queue WHERE run_id=$1',[claim.run_id]))[0].status,'needs_review');
  assert.equal((await q('SELECT auto_enabled FROM cogcor_daemon_private.control'))[0].auto_enabled,false);
  await q(`UPDATE cogcor_daemon_private.control SET max_calls_hour=1`);
  assert.equal((await q('SELECT public.cogcor_daemon_budget_status_v1() s'))[0].s,'call_budget');
  await q(`UPDATE cogcor_daemon_private.control SET max_calls_hour=2,max_cost_usd_24h=0.01`);
  assert.equal((await q('SELECT public.cogcor_daemon_budget_status_v1() s'))[0].s,'cost_budget');
 });
 await test('reservation expiry and execution lease are distinct; expired work stops',async()=>{
  await q(`UPDATE cogcor_daemon_private.control SET auto_enabled=true,auto_started_at=now()-interval '1 hour',auto_approval_id=gen_random_uuid(),auto_reserved_at=now()-interval '5 minutes',auto_execution_deadline_at=now()+interval '5 minutes'`);
  assert.equal((await q('SELECT public.cogcor_daemon_auto_reserve_v1(now()) r'))[0].r.status,'busy_or_pending_approval');
  await q(`UPDATE cogcor_daemon_private.control SET auto_execution_deadline_at=now()-interval '1 second'`);
  assert.equal((await q("SELECT public.cogcor_daemon_auto_reserve_v1(now()+interval '1 minute') r"))[0].r.status,'paused_unfinished_reservation');
  assert.equal((await q('SELECT auto_enabled FROM cogcor_daemon_private.control'))[0].auto_enabled,false);
 });
 await test('backlog stops and summaries remain ineligible',async()=>{
  await q(`UPDATE cogcor_daemon_private.control SET auto_enabled=true,auto_started_at=now()-interval '2 hours',budget_approved_until=now()+interval '1 hour',max_calls_hour=12,max_calls_24h=12,cost_per_call_ceiling_usd=0.01,max_cost_usd_24h=1,pending_candidate_limit=1`);
  await moment('conversation_summary');
  assert.equal((await q('SELECT public.cogcor_daemon_auto_reserve_v1(now()) r'))[0].r.status,'no_eligible_new_event');
  await candidate();
  assert.equal((await q("SELECT public.cogcor_daemon_auto_reserve_v1(now()+interval '1 minute') r"))[0].r.status,'paused_candidate_backlog');
 });
 await test('held candidate later approved retains its linked skill',async()=>{
  const c=await candidate(),review=await moment('user_direct','SYNTHETIC human hold then review','-5 minutes');
  const sql=`SELECT public.cogcor_learning_review_v1($1,$2,$3,'receipt context','expected improvement','compared all active skills','{}') r`;
  await q(sql,[c.p,review,'held']);const result=(await q(sql,[c.p,review,'approved']))[0].r;
  assert.equal((await q('SELECT skill_id FROM cogcor_learning_private.reviews WHERE candidate_id=$1',[c.p]))[0].skill_id,result.skill_id);
 });
 await test('many application increments are atomic and retrieval leaves counters unchanged',async()=>{
  const c=await adopt();
  for(let i=0;i<12;i++){
   const id=uuid();const run=stage=>q(`SELECT public.cogcor_learning_application_v1($1,$2,$3,$4,'synthetic-reference')`,[id,c.s,'synthetic-chat-'+i,stage]);
   await run('retrieved');await run('selected');await run('applied');await run('applied');
  }
  assert.equal((await q('SELECT times_used FROM public.skills WHERE id=$1',[c.s]))[0].times_used,12);
 });

 await test('Japanese search benchmark with synthetic labels, not personal conversations',async()=>{
  const docs=['初期ユナ感は丁寧な相づちから伝わる','右足を休めたという観測結果','あゆみさんと図書館へ行った','フレックス勤務の開始時刻を確認する','領収書の原文を見て番号を回答する','左手でカップを持った','別人のあゆみこさんに連絡した','固定勤務は朝から始まる'];
  const ids=[];for(const d of docs)ids.push(String(await moment('user_direct',d)));
  const cases=[['初期ユナ感',[0]],['右足',[1]],['あゆみさん',[2]],['フレックス',[3]],['ふれっくす',[3]],['領収書 番号 教えて',[4]],['あゆみさん 図書館 前に 教えて',[2]],['右足 休めた 結果 について',[1]],['宇宙船 燃料',[]]];
  const stats={before:{tp:0,fp:0,fn:0,tn:0},after:{tp:0,fp:0,fn:0,tn:0}};
  for(const [query,indexes] of cases){
   const expected=new Set(indexes.map(i=>ids[i]));
   for(const phase of ['before','after']){
    const rows=phase==='before'?await q('SELECT memory_source AS ref FROM cogcor_chat_bridge.recall_baseline($1,20)',[query]):await q('SELECT source_ref AS ref FROM public.cogcor_learning_search_v1($1,20)',[query]);
    const found=new Set(rows.map(r=>r.ref.split(':').at(-1)));
    for(const id of ids){const k=expected.has(id)?found.has(id)?'tp':'fn':found.has(id)?'fp':'tn';stats[phase][k]++;}
   }
  }
  const metrics=Object.fromEntries(Object.entries(stats).map(([phase,s])=>[phase,{...s,precision:s.tp/(s.tp+s.fp||1),recall:s.tp/(s.tp+s.fn||1),false_positive_rate:s.fp/(s.fp+s.tn||1)}]));
  console.log('SEARCH_BENCHMARK',JSON.stringify({queries:cases.length,documents:docs.length,synthetic:true,metrics}));
  assert.ok(metrics.after.recall>=metrics.before.recall);assert.ok(metrics.after.precision>=0.8);
 });

 await test('direct correction preserves the quote and source; duplicate storage is idempotent',async()=>{
  const args=['conversation_event','SYNTHETIC correction: always check the receipt','SYNTHETIC verbatim correction','user_direct','chatgpt_yuna_normal'];
  const sql='SELECT * FROM cogcor_chat_bridge.remember($1,$2,$3,$4,$5)';
  const first=(await q(sql,args))[0],second=(await q(sql,args))[0];
  assert.equal(first.stored,true);assert.equal(second.stored,false);assert.equal(first.memory_source,second.memory_source);
  assert.equal((await q('SELECT source_quote FROM cogcor_chat_bridge.moments WHERE id=$1',[first.memory_source.split(':').at(-1)]))[0].source_quote,args[2]);
 });
 await test('rollback restores original RPCs, retains data, and leaves operation disarmed',async()=>{
  const c=await adopt();await db.exec(read('docs/learning-cycle-20261031/rollback.sql').replace(/^BEGIN;$/m,'').replace(/^COMMIT;$/m,''));
  assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.reviews WHERE candidate_id=$1',[c.p]))[0].n,1);
  assert.equal((await q('SELECT auto_enabled FROM cogcor_daemon_private.control'))[0].auto_enabled,false);
  assert.equal((await q("SELECT has_function_privilege('service_role','public.cogcor_learning_context_v1(text,integer)','EXECUTE') p"))[0].p,false);
 });
 if(nativeSocket){
  const clients=await Promise.all(Array.from({length:8},async()=>{const c=new Client({host:nativeSocket,port:55439,user:'postgres',database:'postgres'});await c.connect();return c;}));
  try{
   const c=await adopt();
   const ids=clients.map(()=>uuid());
   await Promise.all(clients.map(async(client,i)=>{
    const args=[ids[i],c.s,'native-chat-'+i];
    for(const stage of ['retrieved','selected','applied'])await client.query(`SELECT public.cogcor_learning_application_v1($1,$2,$3,$4,'synthetic-response')`,[...args,stage]);
   }));
   assert.equal((await q('SELECT times_used FROM public.skills WHERE id=$1',[c.s]))[0].times_used,8);
   await Promise.all(clients.map(client=>client.query(`SELECT public.cogcor_learning_application_v1($1,$2,'native-chat-0','applied','synthetic-response')`,[ids[0],c.s])));
   assert.equal((await q('SELECT times_used FROM public.skills WHERE id=$1',[c.s]))[0].times_used,8);
   count++;console.log('PASS NATIVE 8 connections: parallel application increments preserved, replay not counted');
   const observations=[];for(let i=0;i<clients.length;i++)observations.push(await moment('observed_result','SYNTHETIC observed benefit '+i,'0 seconds'));
   await Promise.all(clients.map((client,i)=>client.query(`SELECT public.cogcor_learning_application_v1($1,$2,$3,'outcome_observed',NULL,$4)`,[ids[i],c.s,'native-chat-'+i,observations[i]])));
   await Promise.all(clients.map((client,i)=>client.query(`SELECT public.cogcor_learning_score_v1($1,true)`,[ids[i]])));
   assert.deepEqual((await q('SELECT times_used,times_succeeded,times_failed FROM public.skills WHERE id=$1',[c.s]))[0],{times_used:8,times_succeeded:8,times_failed:0});
   count++;console.log('PASS NATIVE 8 connections: concurrent observed scores retain all counts without deadlock');
   await moment('user_direct','SYNTHETIC fresh event for concurrent reservation');await q(`UPDATE cogcor_daemon_private.control SET auto_enabled=true,auto_started_at=now()-interval '2 hours',budget_approved_until=now()+interval '1 hour',max_calls_hour=12,max_calls_24h=12,cost_per_call_ceiling_usd=0.01,max_cost_usd_24h=1`);
   const tick=new Date().toISOString();
   const grants=await Promise.all(clients.map(client=>client.query('SELECT public.cogcor_daemon_auto_reserve_v1($1) r',[tick])));
   const approved=grants.map(x=>x.rows[0].r).filter(r=>r.status==='approved');assert.equal(approved.length,1);
   const claims=await Promise.all(clients.map(client=>client.query('SELECT public.cogcor_daemon_claim_v1($1,false,$2) r',[tick,approved[0].approval_id])));
   assert.equal(claims.filter(x=>x.rows[0].r.status==='claimed').length,1);
   assert.equal((await q('SELECT count(*)::int n FROM cogcor_learning_private.call_reservations'))[0].n,1);
   count++;console.log('PASS NATIVE 8 connections: duplicate Cron and claim produce exactly one run/fee reservation');
  }finally{await Promise.all(clients.map(c=>c.end()));}
 }

 console.log(JSON.stringify({integration_passed:count,remote_calls:0,ai_calls:0}));
} catch(e){console.error('LOCAL TEST FAILED',e.message,e.where);process.exitCode=1;} finally {await db.close();}
