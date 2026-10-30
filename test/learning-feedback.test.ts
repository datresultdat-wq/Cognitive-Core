import { afterEach, describe, expect, it, vi } from 'vitest';
import { fetchObservedOutcomes, runPseudoDaemon } from '../src/pseudo-daemon';
afterEach(()=>vi.unstubAllGlobals());
const approval='10000000-0000-4000-8000-000000000001';
const outcome={outcome_id:'10000000-0000-4000-8000-000000000002',candidate_id:'10000000-0000-4000-8000-000000000003',candidate:'Read the receipt before replying.',score:1,evidence_ref:'cogcor_chat_bridge:moments:42'};
function setup(outcomes:any=[],content='Observed correction',approved=true){
 const calls:any[]=[];const native:any[]=[];
 const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',AI:{run:vi.fn(async(_model:string,_input:any)=>({response:JSON.stringify({reflection:'Unreviewed reflection',candidate:'Check evidence',self_model_question:'Should evidence be checked?'})}))}};
 vi.stubGlobal('fetch',vi.fn(async(input:any,init:any)=>{
  const args=JSON.parse(init.body);calls.push({name:String(input).split('/').at(-1),args});
  if(String(input).endsWith('claim_v1')) return Response.json({status:'claimed',namespace:'production',run_id:'r',inference_approved:approved,event:{id:9,memory_content:content,source_quote:'Actual quote',evidence_type:'user_direct'}});
  if(String(input).endsWith('outcomes_v1'))return Response.json(outcomes);
  return new Response(null,{status:204});
 }));
 const invoke=vi.fn(async(name:string,args:any)=>{native.push({name,args});return {content:[{type:'text',text:JSON.stringify({observed_learning_outcomes:outcomes})}]};});
 return {env,calls,native,invoke};
}
describe('observed feedback and approval boundaries',()=>{
 it('passes sourced positive/negative outcomes unchanged to exactly one model call',async()=>{
  const negative={...outcome,outcome_id:'10000000-0000-4000-8000-000000000004',score:-1};
  const f=setup([outcome,negative]);
  expect(await runPseudoDaemon(f.env,Date.now(),f.invoke,false,approval)).toMatchObject({status:'completed'});
  expect(f.env.AI.run).toHaveBeenCalledTimes(1);
  const input:any=f.env.AI.run.mock.calls[0][1];
  expect(JSON.parse(input.messages[1].content).previously_observed_outcomes).toEqual([outcome,negative]);
  expect(input.max_tokens).toBe(512);
  expect(f.calls[0].args.p_approval_id).toBe(approval);
  expect(f.calls.some(c=>c.args.p_receipt?.observed_outcome_ids?.length===2)).toBe(true);
  expect(f.native.some(c=>c.name==='self_model'&&c.args.action!=='recall')).toBe(false);
 });
 it.each([0,2,null,'1'])('rejects unknown score %s rather than inventing a negative result',async score=>{
  const f=setup([{...outcome,score}]);
  expect(await runPseudoDaemon(f.env,Date.now(),f.invoke,false,approval)).toMatchObject({status:'failed',needs_review:false});
  expect(f.env.AI.run).not.toHaveBeenCalled();
  expect(f.native.some(c=>c.name==='store_reflection')).toBe(false);
 });
 it('rejects missing evidence and more than three outcomes',async()=>{
  const f=setup([{...outcome,evidence_ref:''}]);
  await expect(fetchObservedOutcomes(f.env)).rejects.toThrow();
  const g=setup([outcome,outcome,outcome,outcome]);
  await expect(fetchObservedOutcomes(g.env)).rejects.toThrow();
 });
 it('never infers without a one-shot approval even if the claim is malformed',async()=>{
  const f=setup([]);await runPseudoDaemon(f.env,Date.now(),f.invoke);
  expect(f.env.AI.run).not.toHaveBeenCalled();expect(f.invoke).not.toHaveBeenCalled();
 });
 it('enforces the input byte budget before calling AI',async()=>{
  const f=setup([],'x'.repeat(6100));
  expect(await runPseudoDaemon(f.env,Date.now(),f.invoke,false,approval)).toMatchObject({status:'failed'});
  expect(f.env.AI.run).not.toHaveBeenCalled();
 });
 it('blocks inference when approval flag is false',async()=>{
  const f=setup([],'correction',false);await runPseudoDaemon(f.env,Date.now(),f.invoke,false,approval);
  expect(f.env.AI.run).not.toHaveBeenCalled();
 });
});
