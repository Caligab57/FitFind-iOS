import {createHash} from 'node:crypto';
import {isIP} from 'node:net';
import {ServiceError, validateAnalysis} from './validation.mjs';

export const SHOPPING_VERSION = 'shopping-v1';
export const MAX_PRICE_CENTS = 100_000_000;
const weights = {top:25, bottoms:30, shoes:35, outerwear:45, dress:45, bag:25, accessory:10};
const categoryWords = {
  top: 'shirt tee tshirt blouse top sweater sweatshirt hoodie polo tank jersey turtleneck tunic',
  bottoms: 'pants trouser trousers jeans shorts skirt legging leggings jogger joggers sweatpants chino chinos cargo',
  shoes: 'shoe shoes sneaker sneakers boot boots sandal sandals loafer loafers heel heels flat flats trainer trainers clog clogs mule mules oxford',
  outerwear: 'jacket coat blazer cardigan parka vest overshirt windbreaker puffer trench',
  dress: 'dress gown jumpsuit romper', bag: 'bag tote handbag purse backpack clutch satchel',
  accessory: 'belt hat cap beanie scarf tie necklace ring bracelet watch sunglasses glasses earring earrings sock socks',
};
const stopWords = new Set('a an the and with for of in on by women womens men mens unisex new size fit style clothing'.split(' '));
const tokens = text => [...new Set(String(text).toLowerCase().replace(/t-shirt/g,'tshirt').match(/[a-z0-9]+/g) ?? [])]
  .filter(word => word.length > 1 && !stopWords.has(word));

export function validateShoppingRequest(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some(k => !['analysis','budgetCents','currency'].includes(k)) ||
      body.currency !== 'USD' || !Object.hasOwn(body,'budgetCents') ||
      (body.budgetCents !== null && (!Number.isSafeInteger(body.budgetCents) || body.budgetCents < 100 || body.budgetCents > 1_000_000))) {
    throw new ServiceError(400,'Send an analysis, currency USD, and a total budgetCents from 100 to 1000000, or null for no limit.');
  }
  let analysis;
  try { analysis = validateAnalysis(body.analysis); }
  catch { throw new ServiceError(400,'Send a valid garment analysis before searching for products.'); }
  return {analysis, budgetCents:body.budgetCents, currency:'USD'};
}

// Must match Budget.allocate in the iOS core, including tie order and every cent.
export function allocateBudget(cents, garments) {
  if (cents === null) return garments.map(() => null);
  if (!garments.length) return [];
  const total = garments.reduce((sum,g) => sum + weights[g.category], 0);
  const result = garments.map(g => Math.floor(cents * weights[g.category] / total));
  const remaining = cents - result.reduce((sum,n) => sum + n,0);
  const order = garments.map((g,i) => ({i,remainder:cents * weights[g.category] % total}))
    .sort((a,b) => b.remainder - a.remainder || a.i - b.i);
  for (const {i} of order.slice(0,remaining)) result[i]++;
  return result;
}

export function safeHTTPS(value, {merchant=false} = {}) {
  if (typeof value !== 'string' || value.length > 4096) return null;
  try {
    const url = new URL(value), host = url.hostname.toLowerCase();
    if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
        !host.includes('.') || host.endsWith('.') || isIP(host) || host.startsWith('[') ||
        /(?:^|\.)(localhost|local|internal|test|invalid)$/.test(host)) return null;
    // Don't relabel an aggregator or provider API URL as a merchant purchase page.
    if (merchant && /(?:^|\.)(google\.[a-z.]+|serpapi\.com|googleusercontent\.com|gstatic\.com)$/.test(host)) return null;
    if ([...url.searchParams.keys()].some(k => /^(?:api_key|apikey|access_token|authorization)$/i.test(k))) return null;
    return url.href;
  } catch { return null; }
}

export function safeThumbnail(value) {
  const safe = safeHTTPS(value);
  if (!safe) return null;
  const host = new URL(safe).hostname;
  return /(?:^|\.)(gstatic\.com|googleusercontent\.com)$/.test(host) ? safe : null;
}

export function hasUSDCurrency(record) {
  if (!record || typeof record.price !== 'string' ||
      (record.currency && !['USD','US$','$'].includes(record.currency))) return false;
  return ['USD','US$'].includes(record.currency) || /^(?:US\$|USD\s)/.test(record.price.trim());
}

// US market selection is not a currency guarantee. Require explicit USD evidence;
// bare $ without an explicit currency is excluded, even when Google was queried in the US.
export function usdPriceCents(record) {
  if (!hasUSDCurrency(record) || record.installment) return null;
  const match = record.price.trim().match(/^(?:US\$|\$|USD\s+)((?:\d{1,3}(?:,\d{3})+|\d+))(?:\.(\d{2}))?$/);
  if (!match) return null;
  const cents = Number(match[1].replaceAll(',','')) * 100 + Number(match[2] ?? 0);
  if (!Number.isSafeInteger(cents) || cents <= 0 || cents > MAX_PRICE_CENTS) return null;
  if (record.extracted_price !== undefined &&
      (typeof record.extracted_price !== 'number' || !Number.isFinite(record.extracted_price) ||
       Math.abs(record.extracted_price * 100 - cents) > 0.00001)) return null;
  return cents;
}

export function relevance(garment, title) {
  const words = new Set(tokens(title));
  if (!tokens(categoryWords[garment.category]).some(word => words.has(word))) return null;
  const attributes = tokens(`${garment.name} ${garment.color} ${garment.searchQuery}`);
  const matched = attributes.filter(word => words.has(word));
  if (!matched.length) return null;
  const generic = new Set(Object.values(categoryWords).flatMap(tokens));
  const descriptive = attributes.filter(word => !generic.has(word));
  if (descriptive.length && !descriptive.some(word => words.has(word))) return null;
  // Text-based ranking only. This is not image similarity or verified identity.
  const colors = new Set(tokens(garment.color));
  return {score:matched.reduce((sum,word) => sum + (colors.has(word) ? 3 : 1),0),
    reason:`Listing text matches: ${matched.slice(0,8).join(', ')}. Visual similarity and identity are unverified.`.slice(0,300)};
}

export function normalizeOffer(store, candidate, garment, targetCents) {
  if (!store || typeof store !== 'object') return null;
  const title = typeof store.title === 'string' && store.title.trim() ? store.title.trim() : candidate.title;
  const merchant = typeof store.name === 'string' ? store.name.trim() : '';
  if (typeof title !== 'string' || !title.trim() || title.length > 300 || !merchant || merchant.length > 160) return null;
  const details = Array.isArray(store.details_and_offers) ? store.details_and_offers.filter(s => typeof s === 'string').join(' ') : '';
  if (store.in_stock===false || /out of stock|sold out|unavailable|per month|\/mo\b|subscription|rental|rent per/i.test(`${details} ${title}`)) return null;
  const priceCents = usdPriceCents(store), url = safeHTTPS(store.link,{merchant:true});
  const match = relevance(garment,title);
  if (priceCents === null || (targetCents !== null && priceCents > targetCents) || !url || !match) return null;
  return {
    id:createHash('sha256').update(`${garment.id}\0${url}`).digest('hex').slice(0,24),
    title, merchant, priceCents, currency:'USD', url,
    imageURL:safeThumbnail(candidate.thumbnail), matchType:'similar', matchReason:match.reason,
    score:match.score,
  };
}

export function assembleProducts(request, groups, searchedAt, partial=false, excludedCurrencyCount=0) {
  const targets = allocateBudget(request.budgetCents,request.analysis.garments);
  const garments = request.analysis.garments.map((garment,i) => {
    const seen = new Set();
    const products = (groups[i] ?? []).filter(product => {
      if (!product || product.currency!=='USD' || product.matchType!=='similar' ||
          !Number.isSafeInteger(product.priceCents) || product.priceCents<=0 || product.priceCents>MAX_PRICE_CENTS ||
          (targets[i]!==null && product.priceCents>targets[i]) || !safeHTTPS(product.url,{merchant:true}) ||
          (product.imageURL!==null && product.imageURL!==undefined && !safeThumbnail(product.imageURL)) ||
          !['id','title','merchant','matchReason'].every(key=>typeof product[key]==='string' && product[key].trim()) ||
          product.id.length>80 || product.title.length>300 || product.merchant.length>160 || product.matchReason.length>300) {
        throw new ServiceError(502,'Product search returned an invalid offer.');
      }
      if (seen.has(product.url)) return false;
      seen.add(product.url); return true;
    }).slice(0,3).map(({score,...product}) => product);
    return {garmentId:garment.id,targetCents:targets[i],products};
  });
  const selected = garments.flatMap(g => g.products.slice(0,1));
  return {
    currency:'USD',budgetCents:request.budgetCents,searchedAt,garments,excludedCurrencyCount,
    outfit:{complete:garments.length > 0 && selected.length === garments.length,
      subtotalCents:selected.reduce((sum,p) => sum + p.priceCents,0),selectedProductIds:selected.map(p => p.id)},
    limitations:(partial ? 'Some product searches failed; these results are incomplete. ' : '') +
      (excludedCurrencyCount ? `${excludedCurrencyCount} listings omitted because their currency could not be confirmed as USD. ` : '') +
      'Similar-style candidates ranked by listing text, not visually verified or exact originals. US-market listed prices exclude tax and shipping. Sizes, stock, variants and checkout prices must be checked with the merchant. Per-piece targets may miss alternatives that fit a different budget split.',
  };
}

export async function searchOutfit(request, {provider,signal,now=Date.now}) {
  const targets = allocateBudget(request.budgetCents,request.analysis.garments);
  const groups = new Array(targets.length), failures = [];
  let cursor = 0, succeeded = 0, excludedCurrencyCount = 0;
  async function worker() {
    while (cursor < targets.length) {
      if (signal.aborted) throw signal.reason;
      const i = cursor++;
      try {
        const output = await provider({garment:request.analysis.garments[i],targetCents:targets[i],signal});
        // Arrays remain convenient for a minimal replacement provider and offline tests.
        groups[i] = Array.isArray(output) ? output : output.products;
        const excluded = Array.isArray(output) ? 0 : output.excludedCurrencyCount;
        if (!Array.isArray(groups[i]) || !Number.isSafeInteger(excluded) || excluded<0 || excluded>2000) {
          throw new ServiceError(502,'Product search returned invalid data.');
        }
        excludedCurrencyCount += excluded;
        succeeded++;
      } catch(error) {
        if (signal.aborted) throw error;
        failures.push(error); groups[i] = [];
      }
    }
  }
  await Promise.all(Array.from({length:Math.min(3,targets.length)},worker));
  if (failures.length && !succeeded) throw failures[0];
  return {result:assembleProducts(request,groups,new Date(now()).toISOString(),failures.length > 0,excludedCurrencyCount),partial:failures.length>0};
}
