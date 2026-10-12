import {readFile, stat} from 'node:fs/promises';
import {loadConfig} from '../src/config.mjs';
import {validateShoppingRequest} from '../src/shopping.mjs';

// Manual smoke tests only: analyze/products can make billable provider calls.
try {
  const config=loadConfig();
  const mode=process.argv[2];
  if(!['health','analyze','products'].includes(mode)) throw Error('Use npm run health, analyze -- photo.jpg, or products -- analysis.json 25000 (or unlimited).');
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
  if(mode==='products') {
    const file=process.argv[3], cap=process.argv[4];
    if(!file || !cap) throw Error('Supply an analysis JSON file and budget cents, or unlimited.');
    if((await stat(file)).size>64_000) throw Error('Use an analysis file smaller than 64 KB.');
    const budgetCents=cap==='unlimited'?null:(/^\d+$/.test(cap)?Number(cap):NaN);
    let analysis;
    try {analysis=JSON.parse(await readFile(file,'utf8'));}
    catch {throw Error('The analysis file must contain the direct JSON response from /analyze.');}
    const input=validateShoppingRequest({analysis,budgetCents,currency:'USD'});
    headers['Content-Type']='application/json';body=JSON.stringify(input);
  }
  const response=await fetch(new URL(mode==='health'?'/health':mode==='products'?'/products':'/analyze',origin),{method:mode==='health'?'GET':'POST',headers,body,signal:AbortSignal.timeout(55_000),redirect:'error'});
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
