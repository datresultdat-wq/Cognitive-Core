import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('agents/mcp',()=>({McpAgent:class {env:any;constructor(_s:any,env:any){this.env=env;}static serve(){return {fetch(){}};}static serveSSE(){return {fetch(){}};}}}));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js',()=>({McpServer:class {tool(){}}}));
import worker, { CognitiveCore } from '../src/index';
import { daemonRpc, runPseudoDaemon } from '../src/pseudo-daemon';
afterEach(()=>vi.unstubAllGlobals());

function fixture(options:{failAfterReflection?:boolean}={}) {
 const rows=new Map<string,any[]>();const stages:any[]=[];const finishes:any[]=[];let claimed=false;
 const outbound:string[]=[];
 const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',HF_API_TOKEN:'',AI:{run:vi.fn(()=>{throw new Error('Unexpected paid/model call');})}};
 vi.stubGlobal('fetch',vi.fn(async(input:any,init:any={})=>{
  const url=new URL(String(input));outbound.push(url.href);
  if(url.hostname!=='fixture.invalid')throw new Error('Unexpected external recipient');
  const fn=url.pathname.split('/').at(-1);const args=JSON.parse(init.body||'{}');
  if(fn==='cogcor_processing_moments_v1')return Response.json([]);
  if(fn==='cogcor_daemon_claim_v1'){
   if(claimed)return Response.json({status:'no_unprocessed_event'});
   claimed=true;return Response.json({status:'claimed',namespace:'test',run_id:'trial-run',event:{id:123,evidence_type:'observed_result',memory_content:'Synthetic test receipt',source_quote:null}});
  }
  if(fn==='cogcor_daemon_stage_v1'){stages.push(args);return Response.json(null);}
  if(fn==='cogcor_daemon_candidate_v1'){rows.set('cognitive_proposals',[{test_only:true,...args}]);return Response.json(null);}
  if(fn==='cogcor_daemon_finish_v1'){finishes.push(args);return Response.json(null);}
  if(fn==='cogcor_daemon_test_io_v1'){
   const table=args.p_table;const data=rows.get(table)||[];
   const match=(r:any)=>Object.entries(args.p_filter||{}).every(([k,v])=>r[k]===v);
   if(args.p_op==='query')return Response.json(data.filter(match));
   if(args.p_op==='insert'){
    const row={id:crypto.randomUUID(),times_used:0,times_succeeded:0,times_failed:0,...args.p_data};
    rows.set(table,[...data,row]);
    if(table==='reflections'&&options.failAfterReflection)throw new Error('Connection lost after write');
    return Response.json([row]);
   }
   if(args.p_op==='update'){const changed=data.filter(match);for(const r of changed)Object.assign(r,args.p_data);return Response.json(changed);}
  }
  throw new Error('Unexpected path '+url.pathname);
 }));
 return {env,rows,stages,finishes,outbound};
}

describe('bounded host calls the existing native handlers',()=>{
 it('isolates test outputs, records provenance, and does not learn the same event twice',async()=>{
  const f=fixture();const core=new CognitiveCore({} as any,f.env as any);await core.init();
  const result=await core.runPseudoDaemonTick(Date.now());
  expect(result.status).toBe('completed');
  expect(f.rows.get('reflections')).toHaveLength(1);
  expect(JSON.parse(f.rows.get('reflections')![0].inputs_summary).source_records[0]).toEqual({table:'cogcor_daemon_test.moments',id:'123',role:'supporting',evidence_type:'observed_result'});
  expect(f.rows.get('metacognition_log')).toHaveLength(1);
  expect(f.rows.get('skills')![0]).toMatchObject({times_succeeded:0,source:'cogcor_daemon_test_v1'});
  expect(f.rows.get('companion_preferences')![0]).toMatchObject({confidence:0.3});
  expect(f.stages.filter(s=>s.p_status==='completed').map(s=>s.p_receipt.native_tool)).toContain('self_model');
  expect((await core.runPseudoDaemonTick(Date.now()+60000)).status).toBe('no_unprocessed_event');
  expect(f.rows.get('reflections')).toHaveLength(1);expect(f.env.AI.run).not.toHaveBeenCalled();
  expect(f.outbound.every(url=>url.startsWith('https://fixture.invalid/'))).toBe(true);
 });
 it('holds uncertain writes for review rather than retrying and duplicating them',async()=>{
  const f=fixture({failAfterReflection:true});const core=new CognitiveCore({} as any,f.env as any);await core.init();
  expect(await core.runPseudoDaemonTick(Date.now())).toMatchObject({status:'failed',needs_review:true});
  expect(f.finishes[0].p_retry_safe).toBe(false);
  await core.runPseudoDaemonTick(Date.now()+60000);expect(f.rows.get('reflections')).toHaveLength(1);
 });
 it.each(['disabled','approval_required','busy','duplicate_tick','daily_limit','no_unprocessed_event'])('does not invoke tools or AI when %s',async status=>{
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json({status})));
  const invoke=vi.fn();const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',AI:{run:vi.fn()}};
  expect(await runPseudoDaemon(env,Date.now(),invoke)).toEqual({status});expect(invoke).not.toHaveBeenCalled();expect(env.AI.run).not.toHaveBeenCalled();
 });
 it('rejects any other project before issuing a request',async()=>{
  const fetcher=vi.fn();vi.stubGlobal('fetch',fetcher);
  await expect(daemonRpc({SUPABASE_URL:'https://snnpzlslqbaonxwqbvua.supabase.co',SUPABASE_SERVICE_KEY:'fixture'},'cogcor_daemon_claim_v1',{})).rejects.toThrow('Wrong project');
  expect(fetcher).not.toHaveBeenCalled();
 });
 it('requires well-formed bounded model output before any native write',async()=>{
  const calls:string[]=[];const finish:any[]=[];
  vi.stubGlobal('fetch',vi.fn(async(input:any,init:any)=>{
   if(String(input).endsWith('cogcor_daemon_claim_v1'))return Response.json({status:'claimed',namespace:'production',run_id:'r',inference_approved:true,event:{id:1,memory_content:'not instructions',evidence_type:'user_direct',source_quote:'x'}});
   if(String(input).endsWith('cogcor_daemon_finish_v1'))finish.push(JSON.parse(init.body));
   return Response.json(null);
  }));
  const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',AI:{run:vi.fn(async()=>({response:'{"reflection":"x","candidate":false,"self_model_question":"x","promote_to_essence":true}'}))}};
  expect(await runPseudoDaemon(env,Date.now(),async name=>{calls.push(name);return {content:[{type:'text',text:JSON.stringify({observed_learning_outcomes:[]})}]}; },false,'10000000-0000-4000-8000-000000000001')).toMatchObject({status:'failed',needs_review:false});
  expect(calls).toEqual(['get_processing_context','self_model']);expect(finish[0].p_retry_safe).toBe(false);expect(finish[0].p_error).toBe('AI_OUTPUT_FIELDS');expect(env.AI.run).toHaveBeenCalledTimes(1);
 });
});


describe('manual test entry point', () => {
 const url = 'https://fixture-worker.invalid/api/daemon/test-once';
 function setup() {
  const runner = {setName:vi.fn(async()=>{}),runPseudoDaemonTick:vi.fn(async()=>({status:'completed',test_only:true}))};
  const env = {SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',MCP_API_KEY:'fixture-key',COGNITIVE_CORE:{idFromName:vi.fn(n=>n),get:vi.fn(()=>runner)}};
  return {runner,env};
 }
 it.each([undefined,'wrong'])('rejects absent/wrong auth before accessing DO',async token=>{
  const {runner,env}=setup();
  const response=await worker.fetch(new Request(url,{method:'POST',headers:token?{Authorization:`Bearer ${token}`}:{},body:'{}'}),env as any,{} as any);
  expect(response.status).toBe(401);expect(runner.setName).not.toHaveBeenCalled();
 });
 it('does not accept query-string authentication',async()=>{
  const {runner,env}=setup();
  expect((await worker.fetch(new Request(url+'?key=fixture-key',{method:'POST',body:'{}'}),env as any,{} as any)).status).toBe(401);
  expect(runner.setName).not.toHaveBeenCalled();
 });
 it('forces test-only mode and initializes the DO before executing',async()=>{
  const {runner,env}=setup();
  const response=await worker.fetch(new Request(url,{method:'POST',headers:{Authorization:'Bearer fixture-key'},body:'{}'}),env as any,{} as any);
  expect(response.status).toBe(200);
  expect(runner.setName).toHaveBeenCalledWith('streamable-http:cogcor-pseudo-daemon-test-v1');
  expect(runner.runPseudoDaemonTick).toHaveBeenCalledWith(expect.any(Number),true);
  expect(runner.setName.mock.invocationCallOrder[0]).toBeLessThan(runner.runPseudoDaemonTick.mock.invocationCallOrder[0]);
 });
 it.each([{namespace:'production'},{tool:'store_skill'},null])('rejects caller-controlled options',async body=>{
  const {runner,env}=setup();
  const response=await worker.fetch(new Request(url,{method:'POST',headers:{Authorization:'Bearer fixture-key'},body:JSON.stringify(body)}),env as any,{} as any);
  expect(response.status).toBe(400);expect(runner.runPseudoDaemonTick).not.toHaveBeenCalled();
 });
 it('routes scheduled ticks to a DB-gated production runner',async()=>{
  const runner={setName:vi.fn(async()=>{}),runPseudoDaemonTick:vi.fn(async()=>({status:'disabled'}))};
  const env={COGNITIVE_CORE:{idFromName:vi.fn((n:string)=>n),get:vi.fn(()=>runner)}};
  const pending:Promise<unknown>[]=[];
  const ctx={waitUntil:vi.fn((p:Promise<unknown>)=>pending.push(p))};
  const event={scheduledTime:Date.now()};
  await worker.scheduled(event,env as any,ctx as any);
  await Promise.all(pending);
  expect(runner.setName).toHaveBeenCalledWith('streamable-http:cogcor-pseudo-daemon-production-v1');
  expect(runner.runPseudoDaemonTick).toHaveBeenCalledWith(event.scheduledTime,false);
  expect(ctx.waitUntil).toHaveBeenCalledTimes(1);
 });
 it('blocks a production claim before reading native data or invoking AI',async()=>{
  vi.stubGlobal('fetch',vi.fn(async(input:any)=>Response.json(String(input).endsWith('claim_v1')?{status:'claimed',namespace:'production',run_id:'r',event:{id:1},inference_approved:true}:null)));
  const invoke=vi.fn();const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture',AI:{run:vi.fn()}};
  expect(await runPseudoDaemon(env,Date.now(),invoke,true)).toMatchObject({status:'failed'});
  expect(invoke).not.toHaveBeenCalled();expect(env.AI.run).not.toHaveBeenCalled();
 });
});


describe('PostgREST response contracts',()=>{
 it.each(['stage','candidate','finish'])('accepts empty 204 for void %s RPC',async kind=>{
  vi.stubGlobal('fetch',vi.fn(async()=>new Response(null,{status:204})));
  expect(await daemonRpc({SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture'},`cogcor_daemon_${kind}_v1`,{})).toBeNull();
 });
 it('does not turn an empty claim response into success',async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>new Response(null,{status:204})));
  await expect(daemonRpc({SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture'},'cogcor_daemon_claim_v1',{})).rejects.toThrow();
 });
});


describe('production manual endpoint',()=>{
 it('requires Bearer authentication before accessing a runner',async()=>{
  const get=vi.fn();const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture',MCP_API_KEY:'fixture-key',COGNITIVE_CORE:{get}};
  const r=await worker.fetch(new Request('https://worker.invalid/api/daemon/run-once',{method:'POST',body:'{}'}),env as any,{} as any);
  expect(r.status).toBe(401);expect(get).not.toHaveBeenCalled();
 });
 it.each([{}, {approval_id:'bad'}, {approval_id:'10000000-0000-4000-8000-000000000001',moment_id:1}])('rejects invalid or extra execution options',async body=>{
  const get=vi.fn();const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture',MCP_API_KEY:'fixture-key',COGNITIVE_CORE:{get}};
  const r=await worker.fetch(new Request('https://worker.invalid/api/daemon/run-once',{method:'POST',headers:{Authorization:'Bearer fixture-key'},body:JSON.stringify(body)}),env as any,{} as any);
  expect(r.status).toBe(400);expect(get).not.toHaveBeenCalled();
 });
});
