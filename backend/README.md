# FitFind Backend

A Node development backend for the [FitFind iOS app](../README.md), kept in the same repository under `backend/`. Upload an outfit screenshot and receive structured **garment descriptions**, using Gemini on the server. The existing iOS recognition client can connect without a wire-format change. The service runs separately on your Mac/server; its code and credentials are not bundled into the iOS app.

This is the recognition milestone, not the finished shopping product. It does **not** search Google Lens, identify verified originals, return purchase links, check stock, or invent match confidence. Product retrieval, alternatives and total-budget outfit assembly are the next milestone.

## Run on your Mac

Install Node.js **22.13 or newer**. From the repository root:

```sh
cd backend
npm ci
cp .env.example .env
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

Open `.env` in your editor. Paste the generated random token into `FITFIND_ACCESS_TOKEN`. Set `GEMINI_API_KEY` to your Gemini API key. Keep `.env` out of Git and do not paste either secret into a chat, screenshot or issue. The generated token is a **separate service credential**, not your Gemini key.

```sh
npm start
```

Defaults: `127.0.0.1:8787`, configurable `gemini-2.5-flash`. In a second terminal in the same folder:

```sh
npm run health
```

`ready: true` means a key is configured, **not** that the key, model, billing or quota has been verified. Health is authenticated and never calls Gemini. Without a Gemini key the service still starts and health returns `ready: false`; analysis returns HTTP 503. There is no fake recognition mode.

To explicitly make one real analysis request with an image you have permission to send to Google:

```sh
npm run analyze -- /absolute/path/outfit.jpg "casual streetwear"
```

This command may incur provider charges. Tests do not. A rejected provider call is counted against the per-run ceiling; no automatic retries are made.

## Connect the iOS app

In the app's recognition settings, enter:

| Where the app runs | Backend URL | Server setting |
|---|---|---|
| iOS Simulator on the same Mac | `http://localhost:8787` | Default `HOST=127.0.0.1` |
| Physical iPhone on the same trusted Wi-Fi | `http://Your-Mac.local:8787` | Set `HOST=0.0.0.0`, then restart |
| Hosted server, later | `https://your-backend-domain` | Managed TLS and production security required |

For the phone, replace `Your-Mac.local` with your actual LocalHostName from **System Settings → General → Sharing** (or run `scutil --get LocalHostName` and append `.local`). Allow the server through your Mac firewall if prompted. The iOS client rejects ordinary LAN IP HTTP URLs; use the `.local` hostname. Local-network permission and network/firewall settings can still prevent access. Do not expose this development server via router port forwarding.

Use the same `FITFIND_ACCESS_TOKEN` in the app's service-token field. **Never put the Gemini API key into the app.** Budget changes do not require another recognition call. An existing saved description is not a purchasable product.

## API contract

Both routes require `Authorization: Bearer <FITFIND_ACCESS_TOKEN>`.

`GET /health`:

```json
{"ready":true,"service":"fitfind-backend","version":"0.1.0"}
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

Errors are `{"error":"safe explanation"}` with HTTP 400 (invalid upload), 401 (service token), 404/405 (route/method), 413 (body size), 415 (content type), 429 (local throttling), or 500/502/503/504 (backend/provider failure). No raw provider response is exposed.

## Architecture and safeguards

The iOS app resizes and JPEG-encodes the photo, then sends it to this service. The service authenticates the request, validates and re-encodes the image, calls Gemini with a structured JSON schema, validates the returned fields, and sends garment descriptions back.

* Standard Node HTTP server; `sharp` handles image decoding, orientation, metadata stripping and resizing. No custom computer-vision model to train.
* Still JPEG, PNG or WebP only; at most 3,000,000 image bytes, 4,100,000 JSON body bytes, 25 million pixels and 1,600 pixels on the longest output side. No remote image URLs or URL-fetching endpoint.
* Up to 1,000 characters of context. Context and image text are explicitly treated as untrusted input in the model prompt. This is a mitigation, not a guarantee against prompt injection.
* Gemini Interactions REST API with `store: false`, structured output and a 45-second timeout. The iOS timeout is 55 seconds. Google still processes the image; `store: false` is not a guarantee of zero retention under Google's account/data terms.
* In-memory recognition cache, keyed by normalized image, context, model and prompt version. Up to 100 entries, default five-minute TTL; no images, model responses or uploads written to disk by this service. Images exist in request memory and are sent to Google. The cache stores garment descriptions, not image bytes.
* JSON telemetry contains request IDs, status, latency, cache hit, provider-call count and reported token usage. Never logs photos, context, tokens or raw provider errors.

| Environment variable | Default | Meaning |
|---|---|---|
| `FITFIND_ACCESS_TOKEN` | Required | Random 32–256 character development service token |
| `GEMINI_API_KEY` | Empty | Server-only provider credential |
| `GEMINI_MODEL` | `gemini-2.5-flash` | Configurable compatible model; verify account access |
| `HOST` / `PORT` | `127.0.0.1` / `8787` | Listening address |
| `MAX_REQUESTS_PER_MINUTE` | `20` | Global authenticated analysis requests per fixed minute window |
| `MAX_CONCURRENT_ANALYSES` | `2` | Concurrent analysis slots |
| `MAX_PROVIDER_CALLS_PER_RUN` | `50` | Maximum provider attempts during one server process lifetime |
| `CACHE_TTL_SECONDS` | `300` | Cache TTL; `0` disables it |
| `FITFIND_SERVICE_URL` | `http://127.0.0.1:8787` | Optional origin for manual client scripts only |

**The call ceiling is not a billing hard cap.** It resets when the server restarts and is independent per process. Use provider-side quotas/billing controls as well. The shared token is appropriate for a private development pilot, not public customer authentication. Multiple devices sharing it also share rate limits and cache.

Before a public beta: add individual sign-in and user isolation, persistent per-user quotas, managed HTTPS, abuse protection, secret management, provider billing monitoring, a photo/data policy, and retention/deletion decisions. If uploads are later stored for shopping search, make that an explicit new privacy/data-flow decision.

## Verify without a key

```sh
npm run check
npm test
```

Tests use synthetic images, dummy credentials and mocked provider responses. They cover the iOS JSON contract, image validation, metadata stripping, auth, limits, cache, error privacy, provider request/response parsing, cancellation and timeouts. They prove local behavior, not Gemini model quality or end-to-end operation on an iPhone. The repository's `.github/workflows/backend.yml` runs the same checks on Node 22.

## Next MVP milestone

1. Configure the key locally and run one authorized screenshot through the existing iOS app.
2. Add a replaceable shopping-search provider (Lens access through a permitted third-party API, or a suitable retailer/catalog search), using garment crops and search descriptions.
3. Validate product pages/feed metadata before showing prices, stock or purchase links.
4. Assemble full-outfit alternatives under the user's total budget using integer currency units. Separate exact-identity evidence from visual similarity.
5. Compare the workflow with manual Lens searches on 20–30 real screenshots, then test repeat use and willingness to pay.

Provider references: [Gemini Interactions REST API](https://ai.google.dev/api/interactions-api), [image inputs](https://ai.google.dev/gemini-api/docs/image-understanding), [structured outputs](https://ai.google.dev/gemini-api/docs/structured-output), [API-key safety](https://ai.google.dev/gemini-api/docs/api-key).
