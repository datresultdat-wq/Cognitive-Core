/** Explicit, service-only learning contract. No approval/scoring RPC exposed to the model. */
type Env = { SUPABASE_URL: string; SUPABASE_SERVICE_KEY: string };
const allowed = new Set(['cogcor_learning_context_v1', 'cogcor_learning_application_v1', 'cogcor_learning_search_v1']);
export async function learningRpc(env: Env, name: string, args: Record<string, unknown>) {
  if (!allowed.has(name)) throw new Error('Unsupported learning RPC');
  const url = new URL(env.SUPABASE_URL);
  if (url.hostname !== 'wllbmvnimempkqzgshsi.supabase.co' && url.hostname !== 'fixture.invalid') throw new Error('Wrong project');
  const key = env.SUPABASE_SERVICE_KEY;
  const response = await fetch(`${url.origin}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: { apikey: key, ...(key.startsWith('sb_secret_') ? {} : { Authorization: `Bearer ${key}` }), 'Content-Type': 'application/json' },
    body: JSON.stringify(args), signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`Learning RPC ${name}: HTTP ${response.status}`);
  return response.json();
}
export async function boundedInference<T>(call: () => Promise<T>, timeoutMs = 45000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try { return await Promise.race([call(), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('AI_TIMEOUT')), timeoutMs); })]); }
  finally { if (timer !== undefined) clearTimeout(timer); }
}
