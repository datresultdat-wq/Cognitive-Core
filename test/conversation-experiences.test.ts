import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('agents/mcp', () => ({ McpAgent: class { static serve(){return {fetch(){}};} static serveSSE(){return {fetch(){}};} } }));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js', () => ({ McpServer: class {} }));
import worker, { fetchConversationExperiences } from '../src/index';
afterEach(() => vi.unstubAllGlobals());
const environment = (key='sb_secret_fixture') => ({ SUPABASE_URL:'https://new-project.invalid', SUPABASE_SERVICE_KEY:key, MCP_API_KEY:'fixture-only' });
const event = { id:1, source_ref:'cogcor_chat_bridge:moments:1', evidence_type:'user_direct', source_quote:'fixture correction', verification:'caller_attributed' };
describe('observed conversation experiences',()=>{
 for (const key of ['sb_secret_fixture','eyJ.fixture.jwt']) it(`retains provenance and key mode ${key}`,async()=>{
  vi.stubGlobal('fetch',vi.fn(async(url:any,init:any)=>{
   expect(String(url)).toBe('https://new-project.invalid/rest/v1/rpc/cogcor_processing_moments_v1');
   const headers=new Headers(init.headers); expect(headers.get('apikey')).toBe(key);
   expect(headers.get('authorization')).toBe(key.startsWith('sb_secret_')?null:`Bearer ${key}`);
   expect(JSON.parse(init.body)).toEqual({p_hours:72,p_limit:10});return Response.json([event]);
  }));
  expect(await fetchConversationExperiences(environment(key),999)).toEqual([event]);
 });
 it('propagates permission failure instead of pretending there are no experiences',async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json({error:'denied'},{status:403})));
  await expect(fetchConversationExperiences(environment())).rejects.toThrow('403');
 });
 it('rejects malformed RPC payload',async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json({error:'not rows'})));
  await expect(fetchConversationExperiences(environment())).rejects.toThrow('Invalid conversation experience');
 });
 it('uses the existing native REST processing-context route and keeps all old pools',async()=>{
  const paths:string[]=[];
  vi.stubGlobal('fetch',vi.fn(async(url:any)=>{
   const path=new URL(String(url)).pathname;paths.push(path);
   return Response.json(path.endsWith('cogcor_processing_moments_v1')?[event]:[]);
  }));
  const response=await worker.fetch(new Request('https://new-worker.invalid/api/reflection/context',{method:'POST',headers:{Authorization:'Bearer fixture-only','Content-Type':'application/json'},body:JSON.stringify({hours_back:24})}),environment() as any,{} as any);
  expect(response.status).toBe(200);const payload:any=await response.json();
  expect(payload.conversation_experiences).toEqual([event]);
  expect(payload.experience_coverage).toContain('not_complete_transcript');
  for(const key of ['sessions','recent_memories','emotional_shifts','past_reflections'])expect(payload[key]).toEqual([]);
  expect(paths).toContain('/rest/v1/rpc/cogcor_processing_moments_v1');
  expect(paths.every(path=>path.startsWith('/rest/v1/'))).toBe(true);
 });
 it('rejects an unauthenticated context call before database access',async()=>{
  const fetch=vi.fn();vi.stubGlobal('fetch',fetch);
  const response=await worker.fetch(new Request('https://new-worker.invalid/api/reflection/context',{method:'POST'}),environment() as any,{} as any);
  expect(response.status).toBe(401);expect(fetch).not.toHaveBeenCalled();
 });
});
