// Native CogCor handlers with an in-memory Supabase fixture, NOT production or ChatGPT E2E.
import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('agents/mcp',()=>({McpAgent:class {env:any;constructor(_state:any,env:any){this.env=env;}static serve(){return {fetch(){}};}static serveSSE(){return {fetch(){}};}}}));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js',()=>({McpServer:class {tools=new Map();tool(name:string,...args:any[]){this.tools.set(name,args.at(-1));}}}));
import { CognitiveCore } from '../src/index';
afterEach(()=>vi.unstubAllGlobals());
describe('native cognitive lifecycle plumbing (isolated fixture)',()=>{
 it('uses native reflection, metacognition, self-model, skill recall, outcome and revision across two agent instances',async()=>{
  const db=new Map<string,any[]>();const called:string[]=[];
  vi.stubGlobal('fetch',vi.fn(async(input:any,init:any={})=>{
   const url=new URL(String(input));if(url.hostname==='router.huggingface.co')return Response.json({}, {status:404});
   const table=url.pathname.split('/').at(-1)!;const rows=db.get(table)||[];
   const matches=(row:any)=>[...url.searchParams].every(([k,v])=>!v.startsWith('eq.')||String(row[k])===v.slice(3));
   if(init.method==='POST'){
    const row={id:crypto.randomUUID(),times_used:0,times_succeeded:0,times_failed:0,status:'active',...JSON.parse(init.body)};
    db.set(table,[...rows,row]);return Response.json([row]);
   }
   if(init.method==='PATCH'){
    const changed=rows.filter(matches);for(const row of changed)Object.assign(row,JSON.parse(init.body));
    return Response.json(changed);
   }
   return Response.json(rows.filter(matches));
  }));
  const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',HF_API_TOKEN:'fixture',AI:{run:async()=>({data:[Array(384).fill(0.01)]})}};
  const one=new CognitiveCore({} as any,env as any);await one.init();
  const call=async(agent:any,name:string,args:any)=>{called.push(name);return agent.server.tools.get(name)(args);};
  const evidence=JSON.stringify({test_only:true,source_records:[{table:'cogcor_chat_bridge.moments',id:'fixture-event',role:'supporting'}],evidence_type:'user_direct',quote:'Use the fixture receipt code, not a guessed code.'});
  await call(one,'store_reflection',{content:'A fixture correction calls for checking the receipt.',inputs_summary:evidence,reflection_type:'observation',depth:0,source:'isolated_fixture'});
  await call(one,'metacognition',{action:'log',level:2,pathway:'slow',monitoring:'A fixture guess lacked evidence.',identity_owner:'fixture',actual:'Correction supplied',control_action:'Read the stored rule; do not infer facts'});
  await call(one,'self_model',{action:'set',domain:'communication',observation:'I may guess fixture codes; provisional only.',preference:'Check receipts.',evidence});
  await call(one,'store_skill',{skill_name:'Fixture receipt check',description:'Retrieve a fixture receipt before replying.',approach:JSON.stringify({evidence,guidance:'fixture-code-83726'}),tags:['isolated_fixture'],source:'isolated_fixture'});
  expect(db.get('skills')![0].times_succeeded).toBe(0); // saving is not success
  const two=new CognitiveCore({} as any,env as any);await two.init();
  const recalled=await call(two,'recall_skills',{tag:'isolated_fixture',limit:10});
  const skills=JSON.parse(recalled.content[0].text);expect(JSON.parse(skills[0].approach).guidance).toBe('fixture-code-83726');
  await call(two,'update_skill_outcome',{skill_id:skills[0].id,was_successful:true});
  const pref=db.get('companion_preferences')![0];
  await call(two,'self_model',{action:'confirm',id:pref.id,evidence:'Fixture evaluator observed the retrieved code used; not an insert receipt.'});
  expect(pref.confidence).toBeCloseTo(0.4);
  await call(two,'score_outcome',{target_type:'approach',target_id:skills[0].id,description:'Fixture-only retrieved code comparison',score:5,notes:'Not a real human interaction',source:'isolated_fixture'});
  await call(two,'update_skill_outcome',{skill_id:skills[0].id,was_successful:false});
  await call(two,'self_model',{action:'revise',id:pref.id,preference:'Also inspect the current fixture correction.',evidence:'Fixture failure, not a real user outcome'});
  expect(pref.times_confirmed).toBe(1);expect(pref.times_revised).toBe(1);expect(pref.confidence).toBeCloseTo(0.3);
  expect(pref.graduated).not.toBe(true);
  expect(db.get('skills')![0]).toMatchObject({times_succeeded:1,times_failed:1});
  expect(db.get('reflections')).toHaveLength(1);expect(db.get('metacognition_log')).toHaveLength(1);expect(db.get('outcome_scores')).toHaveLength(1);
  expect(called).toContain('recall_skills');expect(called).toContain('self_model');
 });
});
