import {afterEach,describe,expect,it,vi} from 'vitest';
import {learningRpc,boundedInference} from '../src/learning-contract';
vi.mock('agents/mcp',()=>({McpAgent:class {env:any;constructor(_s:any,e:any){this.env=e;}static serve(){return {fetch(){}};}static serveSSE(){return {fetch(){}};}}}));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js',()=>({McpServer:class {tools=new Map();tool(name:string,...a:any[]){this.tools.set(name,a.at(-1));}}}));
import {CognitiveCore} from '../src/index';
const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture'};
afterEach(()=>{vi.unstubAllGlobals();vi.useRealTimers();});
describe('explicit learning boundary',()=>{
 it('rejects other projects and approval/scoring endpoints before network access',async()=>{
  const fetch=vi.fn();vi.stubGlobal('fetch',fetch);
  await expect(learningRpc({...env,SUPABASE_URL:'https://other.invalid'},'cogcor_learning_context_v1',{})).rejects.toThrow('Wrong project');
  await expect(learningRpc(env,'cogcor_learning_score_v1',{})).rejects.toThrow('Unsupported');
  await expect(learningRpc(env,'cogcor_learning_review_v1',{})).rejects.toThrow('Unsupported');expect(fetch).not.toHaveBeenCalled();
 });
 it('does not disclose upstream bodies or retry authentication errors',async()=>{
  const fetch=vi.fn().mockResolvedValue(new Response('private upstream detail',{status:401}));vi.stubGlobal('fetch',fetch);
  await expect(learningRpc(env,'cogcor_learning_context_v1',{})).rejects.toThrow('HTTP 401');expect(fetch).toHaveBeenCalledTimes(1);
 });
 it('uses secret-key apikey headers without a false bearer token',async()=>{
  const fetch=vi.fn().mockResolvedValue(Response.json({reviewed_skills:[]}));vi.stubGlobal('fetch',fetch);
  await learningRpc(env,'cogcor_learning_context_v1',{p_query:'領収書'});
  expect(fetch.mock.calls[0][1].headers.Authorization).toBeUndefined();
 });
 it('bounds a hanging AI request without retrying it',async()=>{
  vi.useFakeTimers();const call=vi.fn(()=>new Promise<never>(()=>{}));
  const promise=boundedInference(call,20);const assertion=expect(promise).rejects.toThrow('AI_TIMEOUT');await vi.advanceTimersByTimeAsync(21);await assertion;expect(call).toHaveBeenCalledTimes(1);
 });
 it('retrieval does not run embeddings or mutate counters; legacy booleans cannot score',async()=>{
  const fetch=vi.fn().mockResolvedValue(Response.json({reviewed_skills:[],unreviewed_candidates:[],retrieval_is_application:false}));vi.stubGlobal('fetch',fetch);
  const AI={run:vi.fn()};const agent:any=new CognitiveCore({} as any,{...env,AI} as any);await agent.init();
  const result=await agent.server.tools.get('match_skill')({situation:'領収書',limit:3});
  expect(JSON.parse(result.content[0].text).retrieval_is_application).toBe(false);
  expect(fetch.mock.calls.filter(c=>!String(c[0]).endsWith('/usage_logs'))).toHaveLength(1);expect(String(fetch.mock.calls[0][0])).toContain('cogcor_learning_provisional_context_v1');expect(AI.run).not.toHaveBeenCalled();
  const denied=await agent.server.tools.get('update_skill_outcome')({skill_id:crypto.randomUUID(),was_successful:true});expect(denied.isError).toBe(true);expect(fetch.mock.calls.filter(c=>!String(c[0]).endsWith('/usage_logs'))).toHaveLength(1);
 });
 it('forwards explicit application identity and observed event through the sole RPC',async()=>{
  const fetch=vi.fn().mockResolvedValue(Response.json({stage:'outcome_observed'}));vi.stubGlobal('fetch',fetch);
  const agent:any=new CognitiveCore({} as any,env as any);await agent.init();const id=crypto.randomUUID(),skill=crypto.randomUUID();
  await agent.server.tools.get('learning_application')({application_id:id,skill_id:skill,conversation_ref:'opaque-chat',stage:'outcome_observed',observation_id:17});
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({p_id:id,p_skill:skill,p_stage:'outcome_observed',p_observation:17});
 });
});


describe('continuous experience and provisional tools',()=>{
 it('exposes capture, correction and provisional application without inference or formal promotion',async()=>{
  const fetch=vi.fn().mockImplementation(async()=>Response.json({ok:true}));vi.stubGlobal('fetch',fetch);
  const AI={run:vi.fn()},agent:any=new CognitiveCore({} as any,{...env,AI} as any);await agent.init();
  await agent.server.tools.get('capture_experience')({conversation_ref:'chat',message_ref:'message',occurred_at:'2026-11-03T00:00:00Z',kind:'user_fact',content:'Synthetic fact',quote:'Synthetic fact',evidence_type:'user_direct',context_type:'real'});
  const id=crypto.randomUUID(),candidate=crypto.randomUUID();
  await agent.server.tools.get('provisional_application')({application_id:id,candidate_id:candidate,conversation_ref:'chat',stage:'retrieved'});
  await agent.server.tools.get('correct_provisional_learning')({candidate_id:candidate,correction_event_id:42});
  const calls=fetch.mock.calls.filter(c=>!String(c[0]).endsWith('/usage_logs'));
  expect(calls.map(c=>String(c[0]).split('/').at(-1))).toEqual(['cogcor_learning_capture_v1','cogcor_learning_provisional_apply_v1','cogcor_learning_correct_v1']);
  expect(JSON.parse(calls[0][1].body)).toMatchObject({p_evidence:'user_direct',p_context:'real',p_message:'message'});
  expect(JSON.parse(calls[1][1].body)).toMatchObject({p_stage:'retrieved',p_candidate:candidate});
  expect(AI.run).not.toHaveBeenCalled();
 });
});
