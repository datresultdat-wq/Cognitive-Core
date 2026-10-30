import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('agents/mcp',()=>({McpAgent:class {static serve(){return {fetch(){}};}static serveSSE(){return {fetch(){}};}}}));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js',()=>({McpServer:class {tool(){}}}));
import worker from '../src/index';
import { daemonRpc } from '../src/pseudo-daemon';
afterEach(()=>vi.unstubAllGlobals());
const approval='10000000-0000-4000-8000-000000000001';
function setup(grant:unknown={status:'approved',approval_id:approval},result:unknown={status:'completed'},final:unknown={status:'completed'}) {
 const calls:any[]=[];
 vi.stubGlobal('fetch',vi.fn(async(input:any,init:any)=>{
  const name=String(input).split('/').at(-1);calls.push({name,args:JSON.parse(init.body)});
  const output=name==='cogcor_daemon_auto_reserve_v1'?grant:final;
  if(output instanceof Error)throw output;
  return output instanceof Response?output:Response.json(output);
 }));
 const runner={setName:vi.fn(async()=>{}),runPseudoDaemonTick:vi.fn(async()=>{if(result instanceof Error)throw result;return result;})};
 const env={SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'sb_secret_fixture',AI:{run:vi.fn()},COGNITIVE_CORE:{idFromName:(n:string)=>n,get:vi.fn(()=>runner)}};
 const run=async()=>{
  const pending:Promise<unknown>[]=[];
  await worker.scheduled({scheduledTime:Date.now()},env as any,{waitUntil:(p:Promise<unknown>)=>pending.push(p)} as any);
  await Promise.all(pending);
 };
 return {calls,runner,env,run};
}
describe('automatic host fails closed',()=>{
 it.each(['disarmed','invalid_tick','misconfigured','busy_or_pending_approval','paused_after_failure','daily_limit','paused_candidate_backlog','no_eligible_new_event','paused_unfinished_reservation','paused_running_job'])('never invokes a runner for %s',async status=>{
  const f=setup({status});await f.run();expect(f.env.COGNITIVE_CORE.get).not.toHaveBeenCalled();expect(f.env.AI.run).not.toHaveBeenCalled();expect(f.calls).toHaveLength(1);
 });
 it.each([null,{}, {status:'unknown'},{status:'approved',approval_id:'------------------------------------'},{status:'approved'}])('rejects malformed grants',async grant=>{
  const f=setup(grant);await expect(f.run()).rejects.toThrow();expect(f.env.COGNITIVE_CORE.get).not.toHaveBeenCalled();
 });
 it.each([{status:'failed'},{status:'busy'},{status:'daily_limit'},new Error('DO unavailable')])('finalizes unsuccessful runners once without retry',async result=>{
  const f=setup(undefined,result,{status:'disarmed'});await expect(f.run()).rejects.toThrow();
  expect(f.runner.runPseudoDaemonTick).toHaveBeenCalledTimes(1);expect(f.calls).toHaveLength(2);expect(f.calls[1].args).toEqual({p_approval_id:approval,p_success:false});
 });
 it('finalizes failed initialization without running the model',async()=>{
  const f=setup(undefined,undefined,{status:'disarmed'});f.runner.setName.mockRejectedValueOnce(new Error('init failed'));
  await expect(f.run()).rejects.toThrow();expect(f.runner.runPseudoDaemonTick).not.toHaveBeenCalled();expect(f.calls[1].args.p_success).toBe(false);
 });
 it.each([new Error('network lost'),new Response(null,{status:204}),{status:'approval_mismatch'},{status:'disarmed'}])('does not retry after finalization fails',async final=>{
  const f=setup(undefined,undefined,final);await expect(f.run()).rejects.toThrow();expect(f.runner.runPseudoDaemonTick).toHaveBeenCalledTimes(1);expect(f.calls).toHaveLength(2);
 });
 it.each(['auto_reserve','auto_finalize'])('does not accept 204 as a JSON %s receipt',async name=>{
  vi.stubGlobal('fetch',vi.fn(async()=>new Response(null,{status:204})));
  await expect(daemonRpc({SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:'fixture'},`cogcor_daemon_${name}_v1`,{})).rejects.toThrow();
 });
 it('does not call a runner when reservation HTTP fails',async()=>{
  const f=setup(new Response(null,{status:503}));await expect(f.run()).rejects.toThrow();expect(f.runner.runPseudoDaemonTick).not.toHaveBeenCalled();expect(f.calls).toHaveLength(1);
 });
});
