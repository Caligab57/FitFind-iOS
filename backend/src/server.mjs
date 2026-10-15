import http from 'node:http';
import {createHash, randomUUID, timingSafeEqual} from 'node:crypto';
import {prepareImage, ServiceError, validateAnalysis, validateRequest} from './validation.mjs';
import {createGeminiProvider, PROMPT_VERSION} from './gemini.mjs';
import {searchOutfit, SHOPPING_VERSION, validateShoppingRequest} from './shopping.mjs';
import {createSerpApiProvider} from './serpapi.mjs';

async function readBody(req, limit) {
  if (Number(req.headers['content-length']) > limit) throw new ServiceError(413, 'Request exceeds the allowed body size.');
  const chunks=[]; let size=0;
  for await (const chunk of req.iterator({destroyOnReturn:false})) {
    size+=chunk.length;
    if(size>limit) throw new ServiceError(413, 'Request exceeds the allowed body size.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new ServiceError(400, 'Request body must be valid JSON.'); }
}

export function createService(config, {provider = createGeminiProvider(config), shoppingProvider, shoppingFetch, logger = event => console.log(JSON.stringify(event)), now = Date.now} = {}) {
  let active=0, calls=0, shoppingCalls=0, windowStart=now(), requests=0;
  const cache = new Map(), shoppingCache = new Map();
  const productsProvider = shoppingProvider ?? createSerpApiProvider(config,{fetchImpl:shoppingFetch,reserveCall:()=>{
    if(shoppingCalls>=config.maxShoppingCalls) throw new ServiceError(503,'The configured per-run shopping call limit has been reached.');
    shoppingCalls++;
  }});
  const expected = Buffer.from(`Bearer ${config.token}`);
  const server = http.createServer(async (req,res) => {
    const started=now(), requestId=randomUUID(), controller=new AbortController();
    let held=false, status=500, cacheHit=false, usage;
    res.on('close',()=>{if(!res.writableEnded) controller.abort();});
    function send(code, value) {
      status=code;
      if(res.destroyed || controller.signal.aborted) return;
      res.writeHead(code, {'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store',
        'X-Content-Type-Options':'nosniff', 'X-Request-Id':requestId,
        ...(!req.readableEnded?{'Connection':'close'}:{}), ...(code===429?{'Retry-After':'60'}:{})});
      res.end(JSON.stringify(value));
    }
    try {
      const supplied=Buffer.from(req.headers.authorization ?? '');
      if(supplied.length!==expected.length || !timingSafeEqual(supplied,expected)) throw new ServiceError(401,'A valid service access token is required.');
      if(req.method==='GET' && req.url==='/health') {
        // Configuration readiness only; health never makes a paid provider call.
        send(200,{ready:!!config.apiKey,recognitionConfigured:!!config.apiKey,
          shoppingConfigured:!!config.shoppingApiKey,liveVerified:false,
          service:'fitfind-backend',version:'0.2.0'}); return;
      }
      if(!['/analyze','/products'].includes(req.url)) throw new ServiceError(404,'Route not found.');
      if(req.method!=='POST') {res.setHeader('Allow','POST');throw new ServiceError(405,`Use POST ${req.url}.`);}
      if(now()-windowStart>=60000) {windowStart=now();requests=0;}
      if(++requests>config.maxRequests) throw new ServiceError(429,'Too many requests. Wait a minute.');
      if(active>=config.maxConcurrent) throw new ServiceError(429,'The service is busy. Try again shortly.');
      active++; held=true;
      if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) throw new ServiceError(415,'Send application/json.');
      if(req.headers['content-encoding'] && req.headers['content-encoding']!=='identity') throw new ServiceError(415,'Compressed request bodies are not supported.');
      if(req.url==='/products') {
        const input=validateShoppingRequest(await readBody(req,64_000));
        if(!config.shoppingApiKey) throw new ServiceError(503,'Add SERPAPI_API_KEY to the backend environment to enable product search.');
        const key=createHash('sha256').update(SHOPPING_VERSION).update(JSON.stringify(input)).digest('hex');
        for(const [k,v] of shoppingCache) if(v.expires<=now()) shoppingCache.delete(k);
        const cached=shoppingCache.get(key);
        if(cached) {cacheHit=true;send(200,cached.result);return;}
        const signal=AbortSignal.any([controller.signal,AbortSignal.timeout(config.shoppingTimeoutMs)]);
        let output;
        try {output=await searchOutfit(input,{provider:productsProvider,signal,now});}
        catch(error) {
          if(controller.signal.aborted) throw new ServiceError(499,'Request cancelled.');
          if(signal.aborted) throw new ServiceError(504,'Product search timed out. No automatic retry was made.');
          throw error;
        }
        if(config.shoppingCacheTtlMs>0 && !signal.aborted && !output.partial) {
          if(shoppingCache.size>=100) shoppingCache.delete(shoppingCache.keys().next().value);
          shoppingCache.set(key,{result:output.result,expires:now()+config.shoppingCacheTtlMs});
        }
        send(200,output.result);return;
      }
      const {bytes,context}=validateRequest(await readBody(req,config.maxBodyBytes),config.maxImageBytes);
      if(!config.apiKey) throw new ServiceError(503,'Add GEMINI_API_KEY to the backend environment to enable recognition.');
      const image=await prepareImage(bytes);
      if(controller.signal.aborted) throw new ServiceError(499,'Request cancelled.');
      const key=createHash('sha256').update(config.model).update(PROMPT_VERSION).update(JSON.stringify(context)).update(image).digest('hex');
      for(const [k,v] of cache) if(v.expires<=now()) cache.delete(k);
      const cached=cache.get(key);
      if(cached) {cacheHit=true;send(200,cached.analysis);return;}
      if(calls>=config.maxCalls) throw new ServiceError(503,'The configured per-run provider call limit has been reached.');
      // Failed/cancelled attempts count too; remote work may still be billable.
      calls++;
      const output=await provider({image,context,signal:controller.signal});
      const analysis=validateAnalysis(output.analysis); usage=output.usage;
      if(config.cacheTtlMs>0 && !controller.signal.aborted) {
        if(cache.size>=100) cache.delete(cache.keys().next().value);
        cache.set(key,{analysis,expires:now()+config.cacheTtlMs});
      }
      send(200,analysis);
    } catch(error) {
      const code=error instanceof ServiceError?error.status:500;
      send(code,{error:error instanceof ServiceError?error.message:'The service could not complete the request.'});
    } finally {
      if(held) active--;
      // Never log photos, prompts, context, tokens, provider body, or raw errors.
      try {logger({event:'request',requestId,status,durationMs:now()-started,cacheHit,providerCalls:calls,shoppingCalls,
        ...(usage?{usage}: {})});} catch {/* Logging must not interrupt request handling. */}
      // Rejected unread bodies are drained without buffering; the response closes that connection.
      if(!req.readableEnded) {req.resume();}
    }
  });
  server.requestTimeout=15_000;
  server.headersTimeout=10_000;
  server.keepAliveTimeout=5_000;
  server.maxConnections=32;
  return server;
}
