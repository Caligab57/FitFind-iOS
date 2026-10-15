import test from 'node:test';
import assert from 'node:assert/strict';
import {loadConfig} from '../src/config.mjs';
import {createService} from '../src/server.mjs';
import {ServiceError} from '../src/validation.mjs';
import {allocateBudget,assembleProducts,normalizeOffer,relevance,safeHTTPS,searchOutfit,usdPriceCents,validateShoppingRequest} from '../src/shopping.mjs';
import {createSerpApiProvider} from '../src/serpapi.mjs';

const token='s'.repeat(40);
const config=(overrides={})=>({...loadConfig({FITFIND_ACCESS_TOKEN:token,GEMINI_API_KEY:'mock-gemini',SERPAPI_API_KEY:'mock-shopping-secret'}),...overrides});
const garment={id:'tee',category:'top',name:'Boxy graphic tee',color:'White',details:'Dropped shoulders, red print',searchQuery:'white boxy red graphic tee'};
const analysis={summary:'A white tee.',garments:[garment],limitations:'Identity unverified.'};
const request={analysis,budgetCents:5000,currency:'USD'};
const candidate={title:'White boxy red graphic tee',price:'$24.99',extracted_price:24.99,currency:'USD',
  thumbnail:'https://encrypted-tbn0.gstatic.com/tee.jpg',product_id:'product-a',immersive_product_page_token:'opaque-token',product_link:'https://www.google.com/shopping/product/1'};
const store={title:candidate.title,name:'Example shop',link:'https://shop.example.com/tee',price:'$24.99',extracted_price:24.99,currency:'USD',details_and_offers:['In stock online']};
const offer=()=>normalizeOffer(store,candidate,garment,5000);
const success=body=>Response.json({search_metadata:{status:'Success'},...body});

async function fixture(t,overrides={},dependencies={}) {
  const calls=[],events=[];
  const server=createService(config(overrides),{logger:e=>events.push(e),shoppingProvider:async input=>{calls.push(input);return [offer()];},...dependencies});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  t.after(()=>new Promise(r=>server.close(r)));
  const base=`http://127.0.0.1:${server.address().port}`;
  const call=(value=request,options={})=>fetch(base+'/products',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(value),...options});
  return {calls,events,server,base,call};
}

test('shopping config defaults are bounded and keys remain optional',()=>{
  assert.equal(config().maxShoppingCalls,50);assert.equal(config().shoppingDetailsPerGarment,2);
  for(const env of [{MAX_SHOPPING_CALLS_PER_RUN:'0'},{SHOPPING_DETAILS_PER_GARMENT:'4'},{SHOPPING_CACHE_TTL_SECONDS:'901'}]) {
    assert.throws(()=>loadConfig({FITFIND_ACCESS_TOKEN:token,...env}));
  }
  assert.equal(loadConfig({FITFIND_ACCESS_TOKEN:token}).shoppingApiKey,'');
});
test('request accepts only explicit USD and integer cents or null unlimited',()=>{
  assert.deepEqual(validateShoppingRequest(request),request);
  assert.equal(validateShoppingRequest({...request,budgetCents:null}).budgetCents,null);
  for(const value of [{...request,currency:'CAD'},{...request,budgetCents:99},{...request,budgetCents:1.1},{...request,budgetCents:1_000_001},{analysis,currency:'USD'},{...request,imageBase64:'never transmitted'},{...request,analysis:{summary:'bad'}}]) {
    assert.throws(()=>validateShoppingRequest(value),e=>e.status===400);
  }
});
test('allocation mirrors iOS largest remainder and conserves every cent',()=>{
  const garments=['top','bottoms','shoes'].map((category,i)=>({...garment,id:String(i),category}));
  assert.deepEqual(allocateBudget(100,garments),[28,33,39]);
  assert.deepEqual(allocateBudget(10000,garments),[2778,3333,3889]);
  for(const cents of [100,101,9999,25000,1000000]) assert.equal(allocateBudget(cents,garments).reduce((a,b)=>a+b,0),cents);
  assert.deepEqual(allocateBudget(null,garments),[null,null,null]);assert.deepEqual(allocateBudget(100,[]),[]);
});
test('prices reject wrong currencies, ambiguity, installments, zero, overflow and conflicts',()=>{
  for(const [price,cents] of [['$24.99',2499],['USD 20',2000],['US$1,234.56',123456],['$0.01',1]]) assert.equal(usdPriceCents({price,currency:'USD'}),cents);
  for(const price of ['CA$20.00','A$20.00','€20.00','£20.00','20.00','$20 - $30','From $20','$20/mo','$0.00','$1.999','$1,00.00','$1,000,001.00','$NaN','-$20','USD 2e3']) assert.equal(usdPriceCents({price}),null,price);
  for(const record of [{price:'$20',currency:'CAD'},{price:'$20',extracted_price:19},{price:'$20',extracted_price:'20'},{price:'$20',installment:{months:12}}]) assert.equal(usdPriceCents(record),null);
});
test('only public HTTPS URLs without credentials or API keys are returned',()=>{
  assert.equal(safeHTTPS(store.link,{merchant:true}),store.link);
  for(const value of ['http://shop.example.com','javascript:alert(1)','https://user:pass@shop.example.com','https://127.0.0.1/x','https://[::1]/x','https://printer.local/x','https://printer.local./x','https://shop.example.com./x','https://internal/x','https://shop.example.com:8443/x','https://serpapi.com/search?api_key=secret','https://shop.example.com?api_key=secret']) assert.equal(safeHTTPS(value),null,value);
  for(const value of [candidate.product_link,'https://www.google.co.uk/shopping/product/1','https://serpapi.com/search.json']) assert.equal(safeHTTPS(value,{merchant:true}),null);
});
test('text relevance requires a matching garment category and never claims visual certainty',()=>{
  assert.equal(relevance(garment,'white graphic coffee mug'),null);
  assert.ok(relevance(garment,'White boxy graphic tee').score > relevance(garment,'Graphic tee').score);
  assert.match(relevance(garment,candidate.title).reason,/Listing text matches/);
  assert.match(relevance(garment,candidate.title).reason,/unverified/);
});
test('canonical offers use merchant price and links; stock and budget failures drop out',()=>{
  const product=offer();assert.equal(product.priceCents,2499);assert.equal(product.url,store.link);assert.equal(product.matchType,'similar');assert.equal(product.currency,'USD');
  for(const patch of [{price:'$80',extracted_price:80},{price:'€10',extracted_price:10},{details_and_offers:['Sold out']},{link:candidate.product_link},{title:'White ceramic mug'},{name:''}]) assert.equal(normalizeOffer({...store,...patch},candidate,garment,5000),null);
  assert.ok(normalizeOffer({...store,price:'$80',extracted_price:80},candidate,garment,null));
  assert.equal(normalizeOffer(store,{...candidate,thumbnail:'javascript:alert(1)'},garment,5000).imageURL,null);
});
test('outfit assembly sums one offer per garment, preserves missing groups and deduplicates',()=>{
  const two={...request,analysis:{...analysis,garments:[garment,{...garment,id:'tee2'}]}};
  const first=offer(), second={...offer(),id:'second'};
  const result=assembleProducts(two,[[first,first],[second]],'2026-10-12T00:00:00.000Z');
  assert.equal(result.outfit.complete,true);assert.equal(result.outfit.subtotalCents,4998);
  assert.deepEqual(result.outfit.selectedProductIds,[first.id,'second']);assert.equal(result.garments[0].products.length,1);
  assert.ok(result.outfit.subtotalCents<=two.budgetCents);
  const partial=assembleProducts(two,[[first],[]],'2026-10-12T00:00:00.000Z');
  assert.equal(partial.outfit.complete,false);assert.equal(partial.outfit.subtotalCents,2499);assert.equal(partial.garments[1].products.length,0);
  const empty=assembleProducts({...request,analysis:{...analysis,garments:[]}},[],'2026-10-12T00:00:00.000Z');assert.equal(empty.outfit.complete,false);
});
test('response boundary rejects a replacement provider bypassing USD or target rules',()=>{
  for(const patch of [{currency:'CAD'},{priceCents:5001},{priceCents:0},{priceCents:24.99},{matchType:'exact'},{url:'http://shop.example.com'},{imageURL:'file:///image'},{id:''}]) {
    assert.throws(()=>assembleProducts(request,[[{...offer(),...patch}]],'2026-10-12T00:00:00.000Z'),e=>e.status===502);
  }
});
test('SerpApi sends only a garment query and enriches direct merchant offers',async()=>{
  const calls=[];let reserves=0;
  const provider=createSerpApiProvider(config(),{reserveCall:()=>reserves++,fetchImpl:async(url,options)=>{
    calls.push({url:new URL(url),options});return calls.length===1?success({shopping_results:[candidate]}):success({product_results:{stores:[store]}});
  }});
  const result=await provider({garment,targetCents:5000,signal:new AbortController().signal});
  assert.equal(result.products[0].url,store.link);assert.equal(reserves,2);
  const search=calls[0].url.searchParams;assert.equal(search.get('engine'),'google_shopping');assert.equal(search.get('q'),garment.searchQuery);assert.equal(search.get('gl'),'us');assert.equal(search.get('location'),'United States');assert.equal(search.get('max_price'),'50.00');
  assert.equal(search.has('image'),false);assert.equal(search.has('image_url'),false);assert.equal(search.has('context'),false);
  assert.equal(calls[1].url.searchParams.get('engine'),'google_immersive_product');assert.equal(calls[1].url.searchParams.get('page_token'),'opaque-token');
  assert.equal(calls[0].url.origin,'https://serpapi.com');assert.equal(calls[0].options.redirect,'error');
});
test('provider filters/deduplicates before bounded detail fanout; unlimited omits max_price',async()=>{
  const calls=[];
  const provider=createSerpApiProvider(config({shoppingDetailsPerGarment:2}),{fetchImpl:async url=>{
    const parsed=new URL(url);calls.push(parsed);
    if(calls.length===1) return success({shopping_results:[{...candidate,title:'graphic coffee mug'},candidate,candidate,
      {...candidate,product_id:'second',immersive_product_page_token:'second'},{...candidate,product_id:'third',immersive_product_page_token:'third'}]});
    return success({product_results:{stores:[store,{...store,name:'Other',price:'$30.00',extracted_price:30}]}});
  }});
  await provider({garment,targetCents:null,signal:new AbortController().signal});
  assert.equal(calls.length,3);assert.equal(calls[0].searchParams.has('max_price'),false);
});
test('provider rechecks actual merchant price even when search summary was affordable',async()=>{
  let calls=0;
  const provider=createSerpApiProvider(config(),{fetchImpl:async()=>++calls===1?success({shopping_results:[candidate]}):success({product_results:{stores:[{...store,price:'$90.00',extracted_price:90}]}})});
  assert.deepEqual(await provider({garment,targetCents:5000,signal:new AbortController().signal}),{products:[],excludedCurrencyCount:0});
});
test('provider failures are sanitized, bounded and never automatically retried',async()=>{
  for(const status of [401,403,429,500]) {
    let calls=0;const provider=createSerpApiProvider(config(),{fetchImpl:async()=>{calls++;return new Response('mock-shopping-secret private provider body',{status});}});
    await assert.rejects(()=>provider({garment,targetCents:null,signal:new AbortController().signal}),e=>[502,503].includes(e.status)&&!e.message.includes('mock-shopping-secret'));
    assert.equal(calls,1);
  }
  for(const payload of ['not json','x'.repeat(2_000_001),JSON.stringify({error:'private detail'}),JSON.stringify({shopping_results:'invalid'})]) {
    const provider=createSerpApiProvider(config(),{fetchImpl:async()=>new Response(payload)});
    await assert.rejects(()=>provider({garment,targetCents:null,signal:new AbortController().signal}),e=>e.status===502);
  }
});
test('search cancellation prevents fanout; provider timeout is not an empty result',async()=>{
  const aborting=async(_url,{signal})=>new Promise((_,reject)=>{
    if(signal.aborted) reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
  });
  let calls=0;const controller=new AbortController();controller.abort();
  const provider=createSerpApiProvider(config(),{reserveCall:()=>calls++,fetchImpl:aborting});
  await assert.rejects(()=>provider({garment,targetCents:null,signal:controller.signal}),e=>e.status===499);assert.equal(calls,0);
  const keepAlive=setInterval(()=>{},1000);
  try {
    const slow=createSerpApiProvider(config({shoppingProviderTimeoutMs:10}),{fetchImpl:aborting});
    await assert.rejects(()=>slow({garment,targetCents:null,signal:new AbortController().signal}),e=>e.status===504);
  } finally {clearInterval(keepAlive);}
});
test('outfit search limits parallelism and clearly marks partial provider failures',async()=>{
  const many={...request,budgetCents:null,analysis:{...analysis,garments:Array.from({length:7},(_,i)=>({...garment,id:`g${i}`}))}};
  let active=0,peak=0;
  const output=await searchOutfit(many,{signal:new AbortController().signal,provider:async({garment:g})=>{
    active++;peak=Math.max(active,peak);await new Promise(r=>setTimeout(r,2));active--;
    if(g.id==='g3') throw new ServiceError(502,'Provider failed.');
    return [{...offer(),id:g.id}];
  }});
  assert.equal(peak,3);assert.equal(output.partial,true);assert.equal(output.result.garments.length,7);assert.equal(output.result.outfit.complete,false);assert.match(output.result.limitations,/Some product searches failed/);
});
test('HTTP products has separate readiness and missing-key errors without any calls',async t=>{
  const f=await fixture(t,{shoppingApiKey:''});
  const health=await (await fetch(f.base+'/health',{headers:{Authorization:`Bearer ${token}`}})).json();
  assert.equal(health.recognitionConfigured,true);assert.equal(health.shoppingConfigured,false);assert.equal(health.liveVerified,false);
  const response=await f.call();assert.equal(response.status,503);assert.match((await response.json()).error,/SERPAPI_API_KEY/);assert.equal(f.calls.length,0);
  assert.equal((await f.call(request,{headers:{'Content-Type':'application/json'}})).status,401);
});
test('HTTP products reuses search cache, invalidates changed budget and reports original search time',async t=>{
  let clock=Date.parse('2026-10-12T00:00:00.000Z');const f=await fixture(t,{}, {now:()=>clock});
  const first=await f.call();assert.equal(first.status,200);const result=await first.json();assert.equal(result.outfit.subtotalCents,2499);assert.equal(result.garments[0].targetCents,5000);
  clock+=1000;const cached=await (await f.call()).json();assert.equal(cached.searchedAt,result.searchedAt);assert.equal(f.calls.length,1);
  await f.call({...request,budgetCents:6000});assert.equal(f.calls.length,2);
  clock+=300001;await f.call();assert.equal(f.calls.length,3);
  const logs=JSON.stringify(f.events);for(const secret of [token,'mock-shopping-secret',garment.searchQuery]) assert.ok(!logs.includes(secret));
});
test('HTTP products validate body/budget before search and share request rate limits',async t=>{
  const f=await fixture(t,{maxRequests:2});
  assert.equal((await f.call({...request,budgetCents:'5000'})).status,400);assert.equal(f.calls.length,0);
  assert.equal((await f.call()).status,200);assert.equal((await f.call()).status,429);
});
test('HTTP all-provider failure stays an error and partial failure is not cached',async t=>{
  const f=await fixture(t,{}, {shoppingProvider:async()=>{throw new ServiceError(503,'Provider unavailable.');}});
  assert.equal((await f.call()).status,503);
  let calls=0;
  const partial=await fixture(t,{}, {shoppingProvider:async({garment:g})=>{calls++;if(g.id==='second')throw new ServiceError(502,'Failed');return [offer()];}});
  const two={...request,analysis:{...analysis,garments:[garment,{...garment,id:'second'}]}};
  assert.equal((await partial.call(two)).status,200);assert.equal((await partial.call(two)).status,200);assert.equal(calls,4);
});
test('HTTP search disconnect aborts provider and prevents obsolete results',async t=>{
  let enter,stop;const started=new Promise(r=>enter=r),stopped=new Promise(r=>stop=r);
  const f=await fixture(t,{maxConcurrent:1},{shoppingProvider:async({signal})=>{
    enter();return new Promise((_,reject)=>signal.addEventListener('abort',()=>{stop();reject(new ServiceError(499,'Cancelled'));},{once:true}));
  }});
  const controller=new AbortController(),pending=f.call(request,{signal:controller.signal}).catch(e=>e);
  await started;controller.abort();await pending;await stopped;
  assert.equal((await fetch(f.base+'/health',{headers:{Authorization:`Bearer ${token}`}})).status,200);
});

test('bare dollar prices are excluded unless USD has explicit provider evidence',async()=>{
  assert.equal(usdPriceCents({price:'$25.00',extracted_price:25}),null);
  assert.equal(usdPriceCents({price:'$25.00',currency:'$'}),null);
  assert.equal(usdPriceCents({price:'$25.00',currency:'USD'}),2500);
  let calls=0;
  const ambiguous={...store,currency:undefined};
  const provider=createSerpApiProvider(config(),{fetchImpl:async()=>++calls===1?success({shopping_results:[{...candidate,currency:undefined}]}):success({product_results:{stores:[ambiguous,{...store,currency:'CAD'}]}})});
  const output=await provider({garment,targetCents:5000,signal:new AbortController().signal});
  assert.deepEqual(output,{products:[],excludedCurrencyCount:2});
  const result=await searchOutfit(request,{provider:async()=>output,signal:new AbortController().signal});
  assert.equal(result.result.excludedCurrencyCount,2);assert.equal(result.result.outfit.complete,false);
  assert.match(result.result.limitations,/2 listings omitted/);
});

test('matching category alone cannot outweigh contradictory descriptive attributes',()=>{
  assert.equal(relevance({...garment,name:'White oversized tee',color:'white',searchQuery:'white oversized tee'},'Black slim tee'),null);
});

test('HTTP process shopping ceiling counts all adapter calls and cached responses remain usable',async t=>{
  let calls=0;
  const f=await fixture(t,{maxShoppingCalls:2},{shoppingProvider:undefined,shoppingFetch:async()=>{
    calls++;return calls===1?success({shopping_results:[candidate]}):success({product_results:{stores:[store]}});
  }});
  assert.equal((await f.call()).status,200);assert.equal(calls,2);
  const limited=await f.call({...request,budgetCents:6000});assert.equal(limited.status,503);assert.match((await limited.json()).error,/call limit/);assert.equal(calls,2);
  assert.equal((await f.call()).status,200);assert.equal(calls,2);
});
test('HTTP overall product timeout aborts provider rather than reporting empty success',async t=>{
  const f=await fixture(t,{shoppingTimeoutMs:10},{shoppingProvider:async({signal})=>new Promise((_,reject)=>{
    if(signal.aborted) reject(signal.reason);else signal.addEventListener('abort',()=>reject(signal.reason),{once:true});
  })});
  const response=await f.call();assert.equal(response.status,504);assert.match((await response.json()).error,/timed out/);
});
