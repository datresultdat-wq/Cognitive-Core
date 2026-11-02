// Optional macOS native PostgreSQL concurrency runner. Synthetic data only; no TCP listener.
import {mkdtemp,chmod,readFile} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const run=promisify(execFile);
const runtime='/tmp/cogcor-nativepg-20261031/node_modules';
const bin=resolve(runtime,'@embedded-postgres/darwin-arm64/native/bin');
const dir=await mkdtemp('/tmp/cogcor-native-run-');await chmod(dir,0o700);
let started=false;
try {
 await run(resolve(bin,'initdb'),['-D',dir+'/data','-U','postgres','-A','trust','--encoding=UTF8','--locale=C']);
 await run(resolve(bin,'pg_ctl'),['-D',dir+'/data','-l',dir+'/server.log','-o',`-h '' -k ${dir} -p 55439`,'-w','start']);started=true;
 const result=await run(process.execPath,[fileURLToPath(new URL('./test-learning-db.mjs',import.meta.url))],{env:{...process.env,COGCOR_NATIVE_SOCKET:dir,COGCOR_PG_MODULE:resolve(runtime,'pg/lib/index.js')},maxBuffer:1024*1024});
 console.log(result.stdout);if(result.stderr)console.error(result.stderr);
} catch(e){console.error(e.stdout||e.message);if(e.stderr)console.error(e.stderr);process.exitCode=1;}
finally {if(started)await run(resolve(bin,'pg_ctl'),['-D',dir+'/data','-m','fast','-w','stop']);}
