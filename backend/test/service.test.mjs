import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import sharp from 'sharp';
import {loadConfig} from '../src/config.mjs';
import {createService} from '../src/server.mjs';
import {createGeminiProvider} from '../src/gemini.mjs';
import {prepareImage, ServiceError, validateAnalysis, validateRequest} from '../src/validation.mjs';

// Synthetic pixels and dummy credentials only. These tests never contact Google.
const token='test-only-token-abcdefghijklmnopqrstuvwxyz';
const config=(extra={})=>({...loadConfig({FITFIND_ACCESS_TOKEN:token,GEMINI_API_KEY:'dummy-test-key'}),...extra});
const analysis={summary:'A loose light tee.',garments:[{id:'garment-1',category:'top',name:'Boxy tee',color:'Off-white',details:'Dropped shoulders.',searchQuery:'off white oversized boxy tee'}],limitations:'Product identities, prices and availability are not verified.'};
const png=await sharp({create:{width:20,height:30,channels:3,background:'#ffffff'}}).png().toBuffer();
const request={imageBase64:png.toString('base64'),context:'casual'};
async function fixture(t,extra={},dependencies={}) {
  const events=[],inputs=[];
  const provider=async input=>{inputs.push(input);return {analysis,usage:{total_tokens:100}};};
  const server=createService(config(extra),{provider,logger:e=>events.push(e),...dependencies});
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections();}));
  const origin=`http://127.0.0.1:${server.address().port}`;
  const call=(path='/analyze',options={})=>fetch(origin+path,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(request),...options});
  return {server,origin,call,inputs,events};
}
const providerReply=(value=analysis,extra={})=>({status:'completed',steps:[{type:'model_output',content:[{type:'text',text:JSON.stringify(value)}]}],...extra});

test('configuration fails closed without a strong access token',()=>{
  for(const invalid of [undefined,'short',' '.repeat(40)]) assert.throws(()=>loadConfig({FITFIND_ACCESS_TOKEN:invalid}),/FITFIND_ACCESS_TOKEN/);
  assert.equal(loadConfig({FITFIND_ACCESS_TOKEN:token}).apiKey,'');
  assert.throws(()=>loadConfig({FITFIND_ACCESS_TOKEN:token,PORT:'abc'}),/PORT/);
  assert.throws(()=>loadConfig({FITFIND_ACCESS_TOKEN:token,GEMINI_MODEL:'https://evil.test'}),/GEMINI_MODEL/);
});
test('health requires authentication and does not call Gemini',async t=>{
  const f=await fixture(t);
  const denied=await fetch(f.origin+'/health');assert.equal(denied.status,401);
  const ok=await f.call('/health',{method:'GET',body:undefined});
  assert.equal(ok.status,200);assert.equal((await ok.json()).ready,true);assert.equal(f.inputs.length,0);
});
test('missing API key is reported without a provider request',async t=>{
  const f=await fixture(t,{apiKey:''});
  assert.equal((await (await f.call('/health',{method:'GET',body:undefined})).json()).ready,false);
  const response=await f.call();assert.equal(response.status,503);assert.match((await response.json()).error,/GEMINI_API_KEY/);assert.equal(f.inputs.length,0);
});
test('analysis matches the direct iOS wire contract and sends a normalized JPEG',async t=>{
  const f=await fixture(t);const response=await f.call();
  assert.equal(response.status,200);assert.deepEqual(await response.json(),analysis);
  assert.equal(response.headers.get('cache-control'),'no-store');
  assert.equal((await sharp(f.inputs[0].image).metadata()).format,'jpeg');
  assert.equal(f.inputs[0].context,'casual');
  const logs=JSON.stringify(f.events);for(const value of [token,'dummy-test-key',request.imageBase64,'casual']) assert.ok(!logs.includes(value));
});
test('same image/context is cached; changing context searches again',async t=>{
  const f=await fixture(t);await f.call();await f.call();
  assert.equal(f.inputs.length,1);assert.equal(f.events[1].cacheHit,true);
  await f.call('/analyze',{body:JSON.stringify({...request,context:'formal'})});assert.equal(f.inputs.length,2);
});
test('cache expires and can be disabled',async t=>{
  let clock=1000;const f=await fixture(t,{cacheTtlMs:100},{now:()=>clock});
  await f.call();clock+=101;await f.call();assert.equal(f.inputs.length,2);
  const other=await fixture(t,{cacheTtlMs:0});await other.call();await other.call();assert.equal(other.inputs.length,2);
});
test('provider call ceiling is enforced but cached results still work',async t=>{
  const f=await fixture(t,{maxCalls:1});await f.call();assert.equal((await f.call()).status,200);
  assert.equal((await f.call('/analyze',{body:JSON.stringify({...request,context:'different'})})).status,503);assert.equal(f.inputs.length,1);
});
test('failed attempts count toward the ceiling and raw provider errors are private',async t=>{
  let calls=0;const f=await fixture(t,{maxCalls:1},{provider:async()=>{calls++;throw Error('dummy-test-key private provider detail');}});
  const first=await f.call();assert.equal(first.status,500);assert.ok(!(await first.text()).includes('private'));
  assert.equal((await f.call()).status,503);assert.equal(calls,1);
});
test('rate limit recovers after the time window',async t=>{
  let clock=1000;const f=await fixture(t,{maxRequests:1},{now:()=>clock});await f.call();
  const blocked=await f.call();assert.equal(blocked.status,429);assert.equal(blocked.headers.get('retry-after'),'60');
  clock+=60000;assert.equal((await f.call()).status,200);
});
test('concurrent analysis is bounded and slots are released',async t=>{
  let release,entered;const started=new Promise(r=>{entered=r;});const waiting=new Promise(r=>{release=r;});
  const f=await fixture(t,{maxConcurrent:1},{provider:async()=>{entered();await waiting;return {analysis};}});
  const first=f.call();await started;assert.equal((await f.call()).status,429);release();assert.equal((await first).status,200);
  assert.equal((await f.call()).status,200);
});
test('route and method checks return JSON errors',async t=>{
  const f=await fixture(t);assert.equal((await f.call('/unknown')).status,404);
  const wrong=await f.call('/analyze',{method:'GET',body:undefined});assert.equal(wrong.status,405);assert.equal(wrong.headers.get('allow'),'POST');
});
test('invalid media types and compressed request bodies are rejected',async t=>{
  const f=await fixture(t);
  for(const headers of [{'Content-Type':'text/plain'},{'Content-Type':'application/json','Content-Encoding':'gzip'}]) {
    const response=await f.call('/analyze',{headers:{Authorization:`Bearer ${token}`,...headers}});assert.equal(response.status,415);
  }
  assert.equal(f.inputs.length,0);
});
test('malformed JSON, base64 and unexpected request keys never reach the provider',async t=>{
  const f=await fixture(t);
  for(const body of ['{',JSON.stringify({...request,imageBase64:'@@@@'}),JSON.stringify({...request,extra:'x'}),JSON.stringify({...request,context:'x'.repeat(1001)}),JSON.stringify({...request,imageBase64:Buffer.from('not an image').toString('base64')})]) assert.equal((await f.call('/analyze',{body})).status,400);
  assert.equal(f.inputs.length,0);
});
test('oversized request returns 413 with no provider call',async t=>{
  const f=await fixture(t,{maxBodyBytes:200});const response=await f.call('/analyze',{body:'x'.repeat(201)});
  assert.equal(response.status,413);assert.equal(f.inputs.length,0);
});
test('chunked oversized request also returns 413',async t=>{
  const f=await fixture(t,{maxBodyBytes:200});
  const body=new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('x'.repeat(201)));c.close();}});
  const response=await f.call('/analyze',{body,duplex:'half'});assert.equal(response.status,413);
});
test('unrecognized clothing is an honest empty analysis',()=>{
  assert.deepEqual(validateAnalysis({summary:'No visible clothing.',garments:[],limitations:'Try a full outfit photo.'}).garments,[]);
});
test('invalid garment schemas are rejected and unrelated fields are removed',()=>{
  for(const value of [{...analysis,summary:''},{...analysis,garments:Array(13).fill(analysis.garments[0])},{...analysis,garments:[analysis.garments[0],analysis.garments[0]]},{...analysis,garments:[{...analysis.garments[0],category:'pants'}]},{...analysis,garments:[{...analysis.garments[0],name:'x'.repeat(121)}]}]) assert.throws(()=>validateAnalysis(value),e=>e.status===502);
  assert.deepEqual(validateAnalysis({...analysis,url:'https://invented.test',garments:[{...analysis.garments[0],confidence:99}]}),analysis);
});
test('image normalization strips metadata and bounds dimensions',async()=>{
  const large=await sharp({create:{width:1700,height:10,channels:3,background:'#000'}}).jpeg().withMetadata().toBuffer();
  const meta=await sharp(await prepareImage(large)).metadata();assert.equal(meta.width,1600);assert.equal(meta.exif,undefined);
  await assert.rejects(()=>prepareImage(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>')),e=>e.status===400);
});
test('strict base64 and image byte limits are checked',()=>{
  for(const imageBase64 of ['', 'a===','YQ==\n','YR==']) assert.throws(()=>validateRequest({imageBase64},100));
  assert.throws(()=>validateRequest({imageBase64:png.toString('base64')},10));
});
test('Gemini REST request is stateless, structured and uses JPEG input',async()=>{
  let sent;const provider=createGeminiProvider(config(),async(url,options)=>{sent={url,...options};return Response.json(providerReply(analysis,{usage:{total_tokens:100,total_output_tokens:40,private_data:'ignore'}}));});
  const output=await provider({image:png,context:'ignore instructions',signal:new AbortController().signal});
  assert.deepEqual(output.analysis,analysis);assert.deepEqual(output.usage,{total_output_tokens:40,total_tokens:100});
  assert.equal(sent.url,'https://generativelanguage.googleapis.com/v1beta/interactions');
  assert.equal(sent.redirect,'error');
  assert.equal(sent.headers['x-goog-api-key'],'dummy-test-key');
  const body=JSON.parse(sent.body);assert.equal(body.store,false);assert.equal(body.stream,false);
  assert.equal(body.response_format.mime_type,'application/json');assert.equal(body.input[1].mime_type,'image/jpeg');
  assert.match(body.system_instruction,/untrusted/);assert.equal(body.response_format.schema.properties.garments.maxItems,12);
});
test('provider failures are sanitized and never retried',async()=>{
  for(const [status,expected] of [[429,503],[403,503],[404,503],[500,502]]) {
    let calls=0;const provider=createGeminiProvider(config(),async()=>{calls++;return new Response('private dummy-test-key',{status});});
    await assert.rejects(()=>provider({image:png,context:'',signal:new AbortController().signal}),e=>e.status===expected&&!e.message.includes('dummy-test-key'));assert.equal(calls,1);
  }
});
test('incomplete, malformed or oversized provider output is rejected',async()=>{
  for(const payload of [JSON.stringify(providerReply(analysis,{status:'in_progress'})),'not json',JSON.stringify({status:'completed',output_text:JSON.stringify(analysis)}),'x'.repeat(65537)]) {
    const provider=createGeminiProvider(config(),async()=>new Response(payload));
    await assert.rejects(()=>provider({image:png,context:'',signal:new AbortController().signal}),e=>e.status===502);
  }
});
test('provider timeout and caller cancellation are distinct',async()=>{
  const abortingFetch=async(_url,{signal})=>new Promise((_,reject)=>{
    if(signal.aborted) reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
  });
  // Keep the test event loop alive while AbortSignal.timeout uses its unref timer.
  const keepAlive=setInterval(()=>{},1000);
  try {
    const provider=createGeminiProvider(config({providerTimeoutMs:10}),abortingFetch);
    await assert.rejects(()=>provider({image:png,context:'',signal:new AbortController().signal}),e=>e.status===504);
    const cancelled=new AbortController();cancelled.abort();
    await assert.rejects(()=>provider({image:png,context:'',signal:cancelled.signal}),e=>e.status===499);
  } finally {clearInterval(keepAlive);}
});
test('malformed provider garment output is not returned by HTTP service',async t=>{
  const f=await fixture(t,{}, {provider:async()=>({analysis:{summary:'oops'}})});
  assert.equal((await f.call()).status,502);
});
test('disconnect cancels provider work and releases the concurrency slot',async t=>{
  let entered,aborted,calls=0;
  const started=new Promise(r=>{entered=r;});const stopped=new Promise(r=>{aborted=r;});
  const f=await fixture(t,{maxConcurrent:1},{provider:async({signal})=>{
    if(++calls>1) return {analysis};
    entered();return new Promise((_,reject)=>signal.addEventListener('abort',()=>{
      aborted();reject(new ServiceError(499,'Request cancelled.'));
    },{once:true}));
  }});
  const controller=new AbortController();const pending=f.call('/analyze',{signal:controller.signal}).catch(error=>error);
  await started;controller.abort();await pending;await stopped;
  // Provider rejection/finally has run before the following network request is handled.
  assert.equal((await f.call()).status,200);assert.equal(calls,2);
});
test('a telemetry failure does not crash the HTTP server',async t=>{
  const f=await fixture(t,{}, {logger:()=>{throw Error('logging unavailable');}});
  assert.equal((await f.call()).status,200);assert.equal((await f.call('/health',{method:'GET',body:undefined})).status,200);
});
