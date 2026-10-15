# FitFind iOS

Native SwiftUI personal-testing MVP: choose a real outfit photo, add style preferences,
recognize clothing with Gemini through a companion server, and search for similar-style
product listings within a total USD budget. iOS 16+, Xcode 15+; no third-party iOS dependencies.

The recognition backend is included in [`backend/`](backend/README.md). It runs as a
separate Node process on your Mac or server; it is not embedded in the iOS app.

## What works

- Photos picker, orientation-corrected 1600-pixel JPEG preparation without original metadata.
- Live recognition client with consent, cancellation, connection testing, and visible errors.
- Value ($100), Balanced ($250), Premium ($500), Custom ($1-$10,000), and No limit budgets.
- No limit removes price language from shopping searches and hides per-piece allocations;
  it does not verify exact matches, brands, prices, or stock. Saved looks retain this mode.
- Dark editorial interface with condensed typography, restrained lime accents, and matching saved/settings screens.
- Local, deterministic budget allocation. Changing tiers never calls Gemini again.
- Style/occasion context passed to the vision prompt. Updating context requires a new analysis.
- Separate, opt-in SerpApi shopping search retrieves merchant listings and direct product links.
- Alternatives are ranked by listing text against Gemini clothing descriptions. This is not visual
  verification or an exact-original finder; category-only unrelated results are filtered out.
- Strict integer-cent USD prices, per-piece caps, and an honest complete/partial outfit subtotal.
  Ambiguous currencies (including bare `$`) are excluded and counted; see the coverage limit below.
- Google Shopping manual-search links remain an explicitly unverified fallback.
- Save up to 100 looks locally, reopen and delete them. Photos are not persisted by the app.
- Development access token in Keychain. The Gemini API key stays on the Mac/server.

Recognition requires a configured Gemini key and a running companion service. The current
default is `gemini-3.8-flash`; existing server `.env` files must explicitly update `GEMINI_MODEL`
if they still select the old 2.5 default (access to 2.5 is restricted for new projects). Product search
requires a separate server-side SerpApi key. There are no fake recognition or product fallbacks.
Exact product identity, visual candidate comparison, verified inventory, accounts, subscriptions,
and public distribution are not included in this MVP.

Important coverage limit: SerpApi often returns `$` without an ISO currency. US search locale does
not prove USD, so FitFind only displays budget-qualified listings with explicit `USD`/`US$` evidence.
This can leave few or no offers until a catalog with reliable currency metadata is available.
The app explains omissions and retains manual search; it never labels an unknown-currency offer
as within budget. This integration has offline fixtures, not live provider-quality verification.

## Run on your Mac and iPhone

1. Install Xcode 15 or newer and an iOS simulator runtime compatible with your Mac.
   This checkout was created on macOS 13 with command-line tools only. That environment
   cannot build the app or run XCTest. Use a supported Xcode/macOS combination; a newer
   physical iPhone OS may require upgrading macOS and Xcode.
2. Open `FitFind.xcodeproj`. Choose the FitFind scheme and an iPhone simulator. Press Run.
3. For your own iPhone, select your Apple Account's Team under Signing & Capabilities,
   change the bundle identifier if required, connect your phone, enable Developer Mode if
   prompted, choose the device, and Run. Free Personal Team provisioning expires after
   seven days and requires rebuilding/reinstalling.
4. In this checkout, follow [backend/README.md](backend/README.md): install Node 22.13+,
   run `cd backend && npm ci`, copy `.env.example` to `.env`, configure server-only Gemini and SerpApi keys
   and a separate random `FITFIND_ACCESS_TOKEN`, then run `npm start`. Keep secrets
   in `backend/.env` on your Mac; neither provider key may enter the iOS app or Git.
5. In the app's Settings, enter the service address and the matching `FITFIND_ACCESS_TOKEN`.
   The simulator default is `http://localhost:8787`. For an iPhone, use the Mac's Bonjour
   hostname such as `http://My-Mac.local:8787`, with both devices on the same trusted Wi-Fi.
   Obtain the hostname with `scutil --get LocalHostName`; start the server with `HOST=0.0.0.0`.
   Allow local network access on the phone and incoming connections on the Mac if prompted.
6. Tap Test connection and Save. This checks connectivity and configured keys only, not key
   validity, provider billing, or live quality. Select a photo, choose a budget, and tap Find my outfit.
7. Tap Find budget alternatives and review the separate shopping consent. Gemini receives the
   photo for recognition; SerpApi receives only the garment search description for shopping.
   Changing a budget clears stale products and lets you search again without another Gemini call.

Use HTTPS for any nonlocal service. The app permits HTTP only for localhost and `.local`
hosts, with a narrow local-network transport exception. The development token is NOT a
multiuser login system. Do not publicly expose the personal-testing service.

## Architecture

`iPhone -> backend/ Node service -> Gemini Interactions API` (recognition)

`iPhone -> backend/ Node service -> SerpApi Shopping + Immersive Product APIs` (product search)

The server prompts Gemini to describe only visible garments and return validated JSON.
The prompt supplies FitFind's purpose and rules; the user supplies style context. Garment
recognition is independent of budget, making tier changes free of provider calls.
Allocations are spending targets, not model-generated prices. Product search uses the same
largest-remainder allocation, obtains merchant offers through a replaceable provider adapter,
and checks currency and actual offer price again after enrichment. One top-ranked offer per
nonempty garment forms the displayed subtotal, excluding tax and shipping. Missing pieces
are shown as partial; there is no global reallocation optimizer. Sizes, stock, variants and checkout
prices need merchant verification. Saved looks keep descriptions and budget, and search afresh.

Photos are never sent to SerpApi. Raw style notes are not sent to it; generated garment queries
are. SerpApi is a third-party service, not an official Google API. Its retention terms apply. Product
images load from permitted thumbnail hosts and opening a listing contacts the merchant.

Core models and budget arithmetic: `FitFind/Core/Outfit.swift`.
Transport and Keychain: `FitFind/RecognitionClient.swift`.
Photo preparation and local state: `FitFind/OutfitStore.swift`.
Native screens: `ContentView.swift` and `SettingsView.swift`.
Recognition server, image validation, Gemini integration, and offline tests: `backend/`.

## Verification

Open `ContentView.swift` and enable Editor > Canvas for a dark SwiftUI preview.
Preview stores are isolated from saved looks on disk. Use the simulator for photo picking,
recognition, and complete save/reopen/delete flows.

GitHub Actions runs backend checks on Node 22, plus `swift test` and an unsigned iOS simulator build on macOS.
Run backend checks without a Gemini key:

```sh
cd backend
npm ci
npm run check
npm test
```

Backend tests use synthetic images and mocked Gemini/SerpApi responses; they make no billable calls.
Product fixtures with explicit USD evidence validate behavior, not real SerpApi coverage. The
implementation cloud workspace has Node but no Swift/Xcode; local iOS compilation and visual
QA remain unverified until the macOS workflow or an Xcode machine runs these checks.
From the repository root, with full Xcode selected:

```sh
swift test
xcodebuild -project FitFind.xcodeproj -scheme FitFind -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Before considering this ready for external testers, run on a physical phone, test portrait,
landscape, small displays, large Dynamic Type, VoiceOver, denied network access, invalid
credentials, cancellation, changing photos, zero garments, saving/deleting, and 20-30
authorized photos with a live Gemini key. CI compilation is not a visual or recognition-quality test.

## Sustainable API usage

The companion service limits requests and concurrent calls, caches recognition briefly,
caps image size and output tokens, records token counts without photos or prompt text,
and never automatically retries a paid call. The client reuses recognition for budget changes. Product search has a separate per-run call
ceiling, bounded enrichment, a short cache, and no automatic retries; tapping search may incur
SerpApi usage even if no eligible offers are found.
Before public use, add authenticated per-user metering in durable storage, enforce quotas
before provider calls, add a global spending circuit breaker, and set prices from observed
vision + product-search cost per successful outfit. Provider billing alerts alone are not a
hard application spending cap. See [backend safeguards](backend/README.md#architecture-and-safeguards).

Sources: [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding),
[structured outputs](https://ai.google.dev/gemini-api/docs/structured-output),
[API key handling](https://ai.google.dev/gemini-api/docs/api-key),
[Apple device testing](https://developer.apple.com/help/account/basics/about-your-developer-account).
