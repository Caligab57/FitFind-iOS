import {ServiceError} from './validation.mjs';
import {hasUSDCurrency,normalizeOffer,relevance,usdPriceCents} from './shopping.mjs';

async function readJSON(response) {
  const reader = response.body?.getReader();
  if (!reader) throw new ServiceError(502,'Product search returned no data.');
  const chunks=[]; let size=0;
  try {
    while (true) {
      const {done,value}=await reader.read(); if(done) break;
      size+=value.byteLength;
      if(size>2_000_000) {await reader.cancel();throw new ServiceError(502,'Product search returned too much data.');}
      chunks.push(Buffer.from(value));
    }
  } finally {reader.releaseLock();}
  try {return JSON.parse(Buffer.concat(chunks).toString('utf8'));}
  catch {throw new ServiceError(502,'Product search returned invalid data.');}
}

// Replaceable provider boundary: canonical offers in, no provider credentials out.
// https://serpapi.com/google-shopping-api
// https://serpapi.com/google-immersive-product-api
export function createSerpApiProvider(config, {fetchImpl=fetch,reserveCall=()=>{}} = {}) {
  async function query(parameters,signal) {
    if(signal.aborted) throw new ServiceError(499,'Request cancelled.');
    reserveCall(); // Count failed and cancelled attempts too; never retry automatically.
    const combined=AbortSignal.any([signal,AbortSignal.timeout(config.shoppingProviderTimeoutMs)]);
    const url=new URL('https://serpapi.com/search.json');
    for(const [name,value] of Object.entries({...parameters,api_key:config.shoppingApiKey})) url.searchParams.set(name,value);
    try {
      const response=await fetchImpl(url,{signal:combined,redirect:'error',headers:{Accept:'application/json'}});
      if(!response.ok) {
        await response.body?.cancel();
        if([401,403].includes(response.status)) throw new ServiceError(503,'The server SerpApi key is not authorized. Check server configuration.');
        if(response.status===429) throw new ServiceError(503,'Product search quota is exhausted or busy. Try later.');
        throw new ServiceError(502,'The shopping provider could not complete the request.');
      }
      const data=await readJSON(response);
      if(!data || typeof data!=='object' || Array.isArray(data) || data.error ||
          (data.search_metadata?.status && data.search_metadata.status!=='Success')) {
        throw new ServiceError(502,'The shopping provider did not complete the search.');
      }
      return data;
    } catch(error) {
      if(signal.aborted) throw new ServiceError(499,'Request cancelled.');
      if(combined.aborted) throw new ServiceError(504,'Product search timed out. No automatic retry was made.');
      if(error instanceof ServiceError) throw error;
      throw new ServiceError(502,'Could not reach the shopping provider.');
    }
  }
  return async ({garment,targetCents,signal}) => {
    const params={engine:'google_shopping',q:garment.searchQuery,gl:'us',hl:'en',google_domain:'google.com',location:'United States',safe:'active'};
    if(targetCents!==null) params.max_price=(targetCents/100).toFixed(2);
    const data=await query(params,signal);
    if(!Array.isArray(data.shopping_results)) {
      // A successful empty page has no shopping_results. Unexpected types fail closed.
      if(data.shopping_results===undefined && data.search_metadata?.status==='Success') return {products:[],excludedCurrencyCount:0};
      throw new ServiceError(502,'Product search returned an incomplete response.');
    }
    const candidates=data.shopping_results.slice(0,80).map((item,index)=>{
      if(!item || typeof item.title!=='string' || item.title.length>300 ||
          typeof item.immersive_product_page_token!=='string' || item.immersive_product_page_token.length>20_000) return null;
      const price=usdPriceCents(item), match=relevance(garment,item.title);
      // An ambiguous summary may be enriched to look for explicit USD merchant data.
      // It is never used as a quoted price or to qualify an offer for the budget.
      if((hasUSDCurrency(item) && price===null) || item.installment ||
          (price!==null && targetCents!==null && price>targetCents) || !match) return null;
      return {...item,score:match.score,index};
    }).filter(Boolean).sort((a,b)=>b.score-a.score || a.index-b.index);
    const seen = new Set(), offers=[];
    let details=0, excludedCurrencyCount=0;
    for(const candidate of candidates) {
      const identity=candidate.product_id || candidate.immersive_product_page_token;
      if(seen.has(identity)) continue;
      seen.add(identity);
      if(details++>=config.shoppingDetailsPerGarment) break;
      // Never fetch provider-supplied API URLs; fixed API origin + opaque token only.
      const detail=await query({engine:'google_immersive_product',page_token:candidate.immersive_product_page_token},signal);
      if(!Array.isArray(detail.product_results?.stores)) continue;
      const stores=detail.product_results.stores.slice(0,20);
      excludedCurrencyCount+=stores.filter(store=>!hasUSDCurrency(store)).length;
      const variants=stores
        .map(store=>normalizeOffer(store,candidate,garment,targetCents)).filter(Boolean)
        .sort((a,b)=>b.score-a.score || a.priceCents-b.priceCents);
      // One merchant offer per product, so alternatives aren't duplicate stores.
      if(variants.length) offers.push(variants[0]);
    }
    return {products:offers.sort((a,b)=>b.score-a.score || a.priceCents-b.priceCents),excludedCurrencyCount};
  };
}
