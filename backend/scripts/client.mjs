import {readFile, stat} from 'node:fs/promises';
import {loadConfig} from '../src/config.mjs';

// Manual smoke test only: `analyze` can make one billable provider request.
try {
  const config=loadConfig();
  const mode=process.argv[2];
  if(!['health','analyze'].includes(mode)) throw Error('Use npm run health or npm run analyze -- /absolute/path/photo.jpg');
  const base=process.env.FITFIND_SERVICE_URL || `http://127.0.0.1:${config.port}`;
  const origin=new URL(base);
  if(!['http:','https:'].includes(origin.protocol) || !['','/'].includes(origin.pathname) || origin.search || origin.hash || origin.username || origin.password) throw Error('FITFIND_SERVICE_URL must be an HTTP(S) origin without credentials, query or path.');
  if(origin.protocol==='http:' && !['localhost','127.0.0.1'].includes(origin.hostname) && !origin.hostname.endsWith('.local')) throw Error('Use HTTPS except for localhost or your Mac .local address.');
  const headers={Authorization:`Bearer ${config.token}`};
  let body;
  if(mode==='analyze') {
    const file=process.argv[3];if(!file) throw Error('Supply a path to an authorized JPEG, PNG or WebP image.');
    if((await stat(file)).size>config.maxImageBytes) throw Error('Use an image smaller than 3 MB.');
    headers['Content-Type']='application/json';
    body=JSON.stringify({imageBase64:(await readFile(file)).toString('base64'),context:process.argv[4] || ''});
  }
  const response=await fetch(new URL(mode==='health'?'/health':'/analyze',origin),{method:mode==='health'?'GET':'POST',headers,body,signal:AbortSignal.timeout(55_000),redirect:'error'});
  const value=await response.json();
  if(!response.ok) throw Error(`HTTP ${response.status}: ${value.error || 'Request failed.'}`);
  console.log(JSON.stringify(value,null,2));
} catch(error) {
  // Do not print paths, network URLs, raw provider bodies or credentials in failure logs.
  if(error.code) console.error('Could not read the image. Check its path and permissions.');
  else if(error instanceof TypeError || error.name==='TimeoutError') console.error('Could not reach the service. Check it is running and FITFIND_SERVICE_URL is correct.');
  else console.error(error.message);
  process.exitCode=1;
}
