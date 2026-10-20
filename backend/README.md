# FitFind Backend

A Node development backend for the [FitFind iOS app](../README.md), kept in the same repository under `backend/`. Upload an outfit screenshot and receive structured **garment descriptions**, using Gemini on the server. The existing recognition contract stays compatible; the iOS client also supports a separate product-search route. The service runs separately on your Mac/server; its code and credentials are not bundled into the iOS app.

Product search now uses a replaceable SerpApi adapter for Google Shopping queries and bounded Immersive Product enrichment. It returns actual merchant links and listed prices when explicit USD evidence is available, ranked by clothing-description text. It does **not** upload photos to Lens, visually compare product photos, verify originals, promise stock, or invent match confidence.

**Coverage caveat:** current SerpApi examples commonly contain only bare `$`, which does not prove USD. These offers are excluded and counted. The US search locale is never treated as currency evidence, and no conversion is fabricated. This may produce few or no budget-qualified offers. Offline fixtures include explicit USD metadata; they do not prove live retrieval coverage. A future catalog/merchant integration with reliable ISO currency metadata may be needed.

## Run on your Mac

Install Node.js **22.13 or newer**. From the repository root:

```sh
cd backend
npm ci
cp .env.example .env
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

Open `.env` in your editor. Paste the generated random token into `FITFIND_ACCESS_TOKEN`. Set `GEMINI_API_KEY` to your Gemini API key and `SERPAPI_API_KEY` to your separate SerpApi key for product search. Keep `.env` out of Git and do not paste either secret into a chat, screenshot or issue. The generated token is a **separate service credential**, not either provider key.

```sh
npm start
```

Defaults: `127.0.0.1:8787`, configurable `gemini-3.8-flash`. This stable model supports image input and structured output in the current Interactions API. As of October 12, 2026, [Google limits Gemini 2.5 access to previous users](https://ai.google.dev/gemini-api/docs/deprecations), so new projects should not default to it. Existing `.env` files keep their explicit `GEMINI_MODEL`; set `GEMINI_MODEL=gemini-3.8-flash` if migrating from the old default. Account access and live quality still need verification. See the [model capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash).

In a second terminal in the same folder:

```sh
npm run health
```

`recognitionConfigured` and `shoppingConfigured` mean nonempty keys are configured, **not** that credentials, models, billing or quotas have been verified. `liveVerified` is always false; legacy `ready` remains an alias for recognition configuration. Health is authenticated and calls neither provider. Without a Gemini key the service still starts and health returns `ready: false`; analysis returns HTTP 503. There is no fake recognition mode.

To explicitly make one real analysis request with an image you have permission to send to Google:

```sh
npm run analyze -- /absolute/path/outfit.jpg "casual streetwear"
```

This command may incur provider charges. Tests do not. Product searches can also incur SerpApi usage; after saving the direct `/analyze` JSON response to `analysis.json`, explicitly run `npm run products -- analysis.json 25000` for a $250 cap, or replace `25000` with `unlimited`. Never send an image or raw personal style note to the products route. A rejected provider call is counted against the per-run ceiling; no automatic retries are made.

## Connect the iOS app

In the app's recognition settings, enter:

| Where the app runs | Backend URL | Server setting |
|---|---|---|
| iOS Simulator on the same Mac | `http://localhost:8787` | Default `HOST=127.0.0.1` |
| Physical iPhone on the same trusted Wi-Fi | `http://Your-Mac.local:8787` | Set `HOST=0.0.0.0`, then restart |
| Hosted server, later | `https://your-backend-domain` | Managed TLS and production security required |

For the phone, replace `Your-Mac.local` with your actual LocalHostName from **System Settings → General → Sharing** (or run `scutil --get LocalHostName` and append `.local`). Allow the server through your Mac firewall if prompted. The iOS client rejects ordinary LAN IP HTTP URLs; use the `.local` hostname. Local-network permission and network/firewall settings can still prevent access. Do not expose this development server via router port forwarding.

Use the same `FITFIND_ACCESS_TOKEN` in the app's service-token field. **Never put the Gemini API key into the app.** Budget changes do not require another recognition call. They invalidate the old shopping result and allow a new product search. Saved looks store descriptions and budget, not stale product prices; searching a saved look performs a fresh lookup. Product-search consent is separate from photo-analysis consent and can be revoked in Settings.

## Test remotely over cellular

For your own remote testing, use a Cloudflare Quick Tunnel. It creates an outbound
connection from the Mac, so you do not need to open a router port or set `HOST=0.0.0.0`.

Install the tunnel client once:

```sh
brew install cloudflared
```

In Terminal 1, keep the backend running and prevent idle sleep:

```sh
cd backend
caffeinate -i npm start
```

In Terminal 2, from any folder, start the tunnel:

```sh
cloudflared tunnel --url http://127.0.0.1:8787
```

Copy the printed `https://...trycloudflare.com` URL into the iOS app's Settings as the
Recognition service address. Enter the same `FITFIND_ACCESS_TOKEN` from `backend/.env`,
tap **Test connection**, and save. Turn Wi-Fi off on the iPhone and analyze a photo over
cellular. Both Terminal processes must remain running and the Mac must stay online.

The temporary URL changes each time `cloudflared` restarts. Anyone who learns the URL can
reach the service, but every route still requires the long bearer token. Keep both values
private. Quick Tunnels are intended for development and have no uptime guarantee. Do not
enable Cloudflare's email login for this native client; it cannot complete that browser-based
flow. For a stable multi-tester URL, use a named tunnel plus machine-to-machine access tokens
and add server-side validation for those credentials before inviting other users.

## API contract

All routes require `Authorization: Bearer <FITFIND_ACCESS_TOKEN>`.

`GET /health`:

```json
{"ready":true,"recognitionConfigured":true,"shoppingConfigured":true,"liveVerified":false,"service":"fitfind-backend","version":"0.2.0"}
```

`POST /analyze`, `Content-Type: application/json`:

```json
{"imageBase64":"<raw standard base64, without a data URL prefix>","context":"optional style context"}
```

The response is a direct object (not an `analysis` wrapper). **Illustrative shape only**, not a result from a real photograph:

```json
{
  "summary": "Loose tee with dark track pants.",
  "garments": [
    {
      "id": "garment-1",
      "category": "top",
      "name": "Boxy graphic tee",
      "color": "Off-white",
      "details": "Dropped shoulders and a large red graphic.",
      "searchQuery": "off white boxy oversized red graphic tee"
    }
  ],
  "limitations": "Product identities, prices and availability have not been verified."
}
```

Categories: `top`, `bottoms`, `shoes`, `outerwear`, `dress`, `bag`, `accessory`. Maximum 12 garments; IDs must be unique. Empty `garments` is a valid result when no clothing is visible. A valid schema does not guarantee that a model's descriptions are correct; users should review them.

`POST /products`, `Content-Type: application/json` (maximum 64 KB):

```json
{"analysis":{"summary":"...","garments":[],"limitations":"..."},"budgetCents":25000,"currency":"USD"}
```

Pass the validated `/analyze` result as `analysis`. `budgetCents` is an integer from 100 to
1,000,000, or explicit `null` for No limit; currency must be `USD`. No image field is accepted.
The response contains:

- `currency`, `budgetCents`, `searchedAt` (ISO timestamp of the search, retained on cache hits).
- `excludedCurrencyCount`: merchant listings omitted for unknown or unsupported currency.
- `garments`: every input garment, with `garmentId`, exact allocated `targetCents` or null,
  and up to three `products` (two by default). Empty product groups remain present.
- Each product has `id`, `title`, `merchant`, integer `priceCents`, `currency: "USD"`, direct
  HTTPS merchant `url`, optional approved-host `imageURL`, `matchType: "similar"`, and
  `matchReason` describing listing-text overlap. Price/title/link come from provider data,
  never generated by Gemini. Product IDs are stable per garment and merchant URL.
- `outfit`: `complete`, `subtotalCents`, `selectedProductIds`. The first candidate in each
  nonempty group contributes to the subtotal. A complete outfit requires a candidate for
  every garment; an empty analysis is never complete. No missing prices count as zero-price
  products. Each choice fits its per-piece cap, so switching among displayed choices also
  fits the total merchandise cap. Tax and shipping are excluded.
- `limitations`: identity, visual comparison, size/variant, stock, currency omission and
  partial-search caveats. Whole-provider failure returns an error; partial provider failures
  return explicitly incomplete results and are not cached.

Searches use `engine=google_shopping`, `q=<garment.searchQuery>`, `gl=us`, `hl=en`,
`location=United States` and `max_price` when capped. Relevant candidates are resolved using
`engine=google_immersive_product` and the returned `immersive_product_page_token`.
Only HTTPS merchant `stores[].link` values are returned, never Google product/aggregator URLs
as purchase pages. Only explicit `USD`/`US$` currency evidence is eligible; ranges,
installments, inconsistent extracted prices, foreign currencies and known sold-out listings
are excluded. Ambiguous search summaries may be enriched to find an explicit-USD merchant
price, but are never used as quoted prices. Known stock text is only a filter; it is not a live
availability guarantee. At least a category and, when present, a descriptive attribute must
match listing text. This is a conservative heuristic and needs real-photo evaluation.

Errors are `{"error":"safe explanation"}` with HTTP 400 (invalid upload), 401 (service token), 404/405 (route/method), 413 (body size), 415 (content type), 429 (local throttling), or 500/502/503/504 (backend/provider failure). No raw provider response is exposed.

## Architecture and safeguards

The iOS app resizes and JPEG-encodes the photo, then sends it to this service. The service authenticates the request, validates and re-encodes the image, calls Gemini with a structured JSON schema, validates the returned fields, and sends garment descriptions back.

* Standard Node HTTP server; `sharp` handles image decoding, orientation, metadata stripping and resizing. No custom computer-vision model to train.
* Still JPEG, PNG or WebP only; at most 3,000,000 image bytes, 4,100,000 JSON body bytes, 25 million pixels and 1,600 pixels on the longest output side. No remote image URLs or URL-fetching endpoint.
* Up to 1,000 characters of context. Context and image text are explicitly treated as untrusted input in the model prompt. This is a mitigation, not a guarantee against prompt injection.
* Gemini Interactions REST API with `store: false`, structured output and a 45-second timeout. The iOS timeout is 55 seconds. Google still processes the image; `store: false` is not a guarantee of zero retention under Google's account/data terms.
* In-memory recognition cache, keyed by normalized image, context, model and prompt version. Up to 100 entries, default five-minute TTL; no images, model responses or uploads written to disk by this service. Images exist in request memory and are sent to Google. The cache stores garment descriptions, not image bytes.
* Product requests have a 45-second overall deadline and 12-second per-call deadline. At most three garments are searched concurrently per request. Each garment uses one search plus at most two detail calls by default (maximum three), with no pagination or automatic retries. There can be fewer alternatives than requested, especially with strict currency filtering.
* A separate in-memory product cache holds at most 100 complete-search responses for five minutes. Partial technical failures are not cached; empty but successfully searched results can be cached. Descriptions/products remain in memory; no photos are involved in shopping. The SerpApi adapter can be replaced without changing the iOS contract.
* SerpApi receives garment search descriptions only, never the image, raw style note, full analysis, service token or Gemini key. SerpApi is a third party, not an official Google API. Its default search retention is up to 31 days under its [terms](https://serpapi.com/legal); the 10-minute expiry of an image ID would not be a deletion promise, and this integration does not upload images at all.
* The backend calls only fixed provider origins and does not fetch retailer pages or arbitrary image URLs. API redirects and iOS service redirects are refused. Product thumbnails are limited to HTTPS Google thumbnail hosts; merchant links open only on explicit user taps.
* JSON telemetry contains request IDs, status, latency, cache hit, separate provider-call counts and reported token usage. Never logs photos, context, tokens or raw provider errors.

| Environment variable | Default | Meaning |
|---|---|---|
| `FITFIND_ACCESS_TOKEN` | Required | Random 32–256 character development service token |
| `GEMINI_API_KEY` | Empty | Server-only provider credential |
| `SERPAPI_API_KEY` | Empty | Server-only third-party shopping credential |
| `GEMINI_MODEL` | `gemini-3.8-flash` | Configurable compatible model; verify account access |
| `HOST` / `PORT` | `127.0.0.1` / `8787` | Listening address |
| `MAX_REQUESTS_PER_MINUTE` | `20` | Global authenticated analysis and product requests per fixed minute window |
| `MAX_CONCURRENT_ANALYSES` | `2` | Shared concurrent analysis/product slots |
| `MAX_PROVIDER_CALLS_PER_RUN` | `50` | Maximum provider attempts during one server process lifetime |
| `MAX_SHOPPING_CALLS_PER_RUN` | `50` | Maximum SerpApi attempts per server process; failures count |
| `SHOPPING_DETAILS_PER_GARMENT` | `2` | Enrich at most 1–3 candidate products per garment |
| `SHOPPING_CACHE_TTL_SECONDS` | `300` | Product-result cache TTL, 0–900 seconds |
| `CACHE_TTL_SECONDS` | `300` | Cache TTL; `0` disables it |
| `FITFIND_SERVICE_URL` | `http://127.0.0.1:8787` | Optional origin for manual client scripts only |

**The call ceiling is not a billing hard cap.** It resets when the server restarts and is independent per process. Use provider-side quotas/billing controls as well. The shared token is appropriate for a private development pilot, not public customer authentication. Multiple devices sharing it also share rate limits and cache.

Before a public beta: add individual sign-in and user isolation, persistent per-user quotas, managed HTTPS, abuse protection, secret management, provider billing monitoring, a photo/data policy, and retention/deletion decisions. If uploads are later stored for shopping search, make that an explicit new privacy/data-flow decision.

## Verify without a key

```sh
npm run check
npm test
```

Tests use synthetic images, dummy credentials and mocked provider responses. They cover both iOS JSON contracts, exact cent allocation, explicit currency evidence, ambiguous-dollar exclusion counts, merchant-link validation, text-match filtering, bounded fanout, product caches, call ceilings, partial failures, image validation, metadata stripping, auth, error privacy, cancellation and timeouts. They prove local behavior, not Gemini model quality or end-to-end operation on an iPhone. The repository's `.github/workflows/backend.yml` runs the same checks on Node 22.

## Live acceptance checks still required

1. Configure keys on the server without committing them. Test connection only establishes
   connectivity/configuration; it does not validate keys, provider balance or quality.
2. With permission to send the selected photo to Google and incur usage, run recognition.
3. With shopping consent, search its garment descriptions. Inspect how often live merchant
   responses carry explicit USD metadata. Do not relax currency guards to make a demo work.
4. Compare actual listings with 20–30 authorized screenshots. Measure useful candidate rate,
   currency-related omissions, latency, total provider calls, and outfit completion rate.
5. On an iPhone, test search/cancel/retry, photo changes, context changes, invalid and changed
   budgets, saved looks, missing keys, expired quota, partial results, small screens, Dynamic
   Type and VoiceOver. Run `swift test` and the unsigned simulator build on macOS/Xcode.

The implementation workspace ran offline Node checks only; no live credentials, provider
calls, iOS compilation or visual device verification are claimed by this change.

Provider references: [Gemini Interactions REST API](https://ai.google.dev/api/interactions-api), [image inputs](https://ai.google.dev/gemini-api/docs/image-understanding), [structured outputs](https://ai.google.dev/gemini-api/docs/structured-output), [API-key safety](https://ai.google.dev/gemini-api/docs/api-key).

Shopping references: [SerpApi Shopping](https://serpapi.com/google-shopping-api), [result fields](https://serpapi.com/shopping-results), [Immersive Product/stores](https://serpapi.com/google-immersive-product-api), [terms and retention](https://serpapi.com/legal).
