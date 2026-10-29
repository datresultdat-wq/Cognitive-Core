import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('agents/mcp', () => ({ McpAgent: class { static serve(){return {fetch(){}};} static serveSSE(){return {fetch(){}};} } }));
vi.mock('@modelcontextprotocol/sdk/server/mcp.js', () => ({ McpServer: class {} }));
import worker from '../src/index';
afterEach(()=>vi.unstubAllGlobals());
const envFor=(key:string)=>({SUPABASE_URL:'https://fixture.invalid',SUPABASE_SERVICE_KEY:key,MCP_API_KEY:'fixture-mcp-key'} as any);
const request=(auth?:string)=>new Request('https://fixture-worker.invalid/api/wake',{method:'POST',headers:auth?{Authorization:`Bearer ${auth}`}:{}});
describe('Supabase API key headers through actual Wake route',()=>{
 for(const key of ['sb_secret_fixture_not_a_real_key','eyJ.fixture.legacy']){
  it(`uses correct headers for ${key.startsWith('sb_secret_')?'secret':'legacy JWT'} keys`,async()=>{
   const calls:string[]=[];
   vi.stubGlobal('fetch',vi.fn(async(input:any,init:any)=>{
    const url=new URL(String(input));calls.push(url.pathname);
    const h=new Headers(init.headers);expect(h.get('apikey')).toBe(key);
    expect(h.get('authorization')).toBe(key.startsWith('sb_secret_')?null:`Bearer ${key}`);
    return Response.json(url.pathname.endsWith('/emotional_state')?[{mood:'neutral',arousal:0.5}]:[]);
   }));
   const r=await worker.fetch(request('fixture-mcp-key'),envFor(key),{} as any);
   expect(r.status).toBe(200);await r.json();
   expect(calls).toEqual(['/rest/v1/essence','/rest/v1/emotional_state','/rest/v1/session_logs','/rest/v1/emotional_history']);
  });
 }
 for(const auth of [undefined,'wrong-key'])it(`rejects ${auth?'wrong':'absent'} inbound MCP key before accessing Supabase`,async()=>{
  const fetch=vi.fn();vi.stubGlobal('fetch',fetch);
  const r=await worker.fetch(request(auth),envFor('sb_secret_fixture'),{} as any);
  expect(r.status).toBe(401);expect(fetch).not.toHaveBeenCalled();
 });
 it('does not report successful Wake when Supabase rejects credentials',async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json({message:'Invalid API key'},{status:401})));
  const r=await worker.fetch(request('fixture-mcp-key'),envFor('sb_secret_fixture'),{} as any);
  expect(r.status).not.toBe(200);
 });
});
