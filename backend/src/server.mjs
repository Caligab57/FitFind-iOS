import http from 'node:http';
import {createHash, randomUUID, timingSafeEqual} from 'node:crypto';
import {prepareImage, ServiceError, validateAnalysis, validateRequest} from './validation.mjs';
import {createGeminiProvider, PROMPT_VERSION} from './gemini.mjs';

async function readBody(req, limit) {
  if (Number(req.headers['content-length']) > limit) throw new ServiceError(413, 'Request exceeds 4.1 MB.');
  const chunks=[]; let size=0;
  for await (const chunk of req.iterator({destroyOnReturn:false})) {
    size+=chunk.length;
    if(size>limit) throw new ServiceError(413, 'Request exceeds 4.1 MB.');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new ServiceError(400, 'Request body must be valid JSON.'); }
}

export function createService(config, {provider = createGeminiProvider(config), logger = event => console.log(JSON.stringify(event)), now = Date.now} = {}) {
  let active=0, calls=0, windowStart=now(), requests=0;
  const cache = new Map();
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
        send(200,{ready:!!config.apiKey,service:'fitfind-backend',version:'0.1.0'}); return;
      }
      if(req.url!=='/analyze') throw new ServiceError(404,'Route not found.');
      if(req.method!=='POST') {res.setHeader('Allow','POST');throw new ServiceError(405,'Use POST /analyze.');}
      if(now()-windowStart>=60000) {windowStart=now();requests=0;}
      if(++requests>config.maxRequests) throw new ServiceError(429,'Too many analysis requests. Wait a minute.');
      if(active>=config.maxConcurrent) throw new ServiceError(429,'Analysis is busy. Try again shortly.');
      active++; held=true;
      if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) throw new ServiceError(415,'Send application/json.');
      if(req.headers['content-encoding'] && req.headers['content-encoding']!=='identity') throw new ServiceError(415,'Compressed request bodies are not supported.');
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
      try {logger({event:'request',requestId,status,durationMs:now()-started,cacheHit,providerCalls:calls,
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
