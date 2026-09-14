# FitFind iOS

Native SwiftUI personal-testing MVP: choose a real outfit photo, add style preferences,
recognize clothing with Gemini through a companion server, and divide a total USD budget
across the detected pieces. iOS 16+, Xcode 15+; no third-party iOS dependencies.

## What works

- Photos picker, orientation-corrected 1600-pixel JPEG preparation without original metadata.
- Live recognition client with consent, cancellation, connection testing, and visible errors.
- Value ($100), Balanced ($250), Premium ($500), Custom ($1-$10,000), and No limit budgets.
- No limit removes price language from shopping searches and hides per-piece allocations;
  it does not verify exact matches, brands, prices, or stock. Saved looks retain this mode.
- Dark editorial interface with condensed typography, restrained lime accents, and matching saved/settings screens.
- Local, deterministic budget allocation. Changing tiers never calls Gemini again.
- Style/occasion context passed to the vision prompt. Updating context requires a new analysis.
- Shopping search links for each garment. These are NOT verified products, prices, or stock.
- Save up to 100 looks locally, reopen and delete them. Photos are not persisted by the app.
- Development access token in Keychain. The Gemini API key stays on the Mac/server.

Recognition requires a configured Gemini key and a running companion service. There is no
fake recognition fallback. Retailer retrieval, exact product matching, accounts, subscriptions,
and public distribution are not included in this MVP.

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
4. Clone/update [Caligab57/FitFind](https://github.com/Caligab57/FitFind) and follow
   [vision-service/README.md](https://github.com/Caligab57/FitFind/blob/main/vision-service/README.md).
   No web dependency installation is needed for that service.
5. In the app's Settings, enter the service address and the matching `FITFIND_ACCESS_TOKEN`.
   The simulator default is `http://localhost:8787`. For an iPhone, use the Mac's Bonjour
   hostname such as `http://My-Mac.local:8787`, with both devices on the same trusted Wi-Fi.
   Obtain the hostname with `scutil --get LocalHostName`; start the server with `HOST=0.0.0.0`.
   Allow local network access on the phone and incoming connections on the Mac if prompted.
6. Tap Test connection, Save, select an outfit photo, choose your budget, and tap Find my outfit.

Use HTTPS for any nonlocal service. The app permits HTTP only for localhost and `.local`
hosts, with a narrow local-network transport exception. The development token is NOT a
multiuser login system. Do not publicly expose the personal-testing service.

## Architecture

`iPhone -> FitFind companion server -> Gemini Interactions API`

The server prompts Gemini to describe only visible garments and return validated JSON.
The prompt supplies FitFind's purpose and rules; the user supplies style context. Garment
recognition is independent of budget, making tier changes free of provider calls.
Allocations are spending targets, not model-generated prices. Search links open Google
Shopping; they do not guarantee a matching product at the target price.

Core models and budget arithmetic: `FitFind/Core/Outfit.swift`.
Transport and Keychain: `FitFind/RecognitionClient.swift`.
Photo preparation and local state: `FitFind/OutfitStore.swift`.
Native screens: `ContentView.swift` and `SettingsView.swift`.

## Verification

Open `ContentView.swift` and enable Editor > Canvas for a dark SwiftUI preview.
Preview stores are isolated from saved looks on disk. Use the simulator for photo picking,
recognition, and complete save/reopen/delete flows.

GitHub Actions runs `swift test` and an unsigned iOS simulator build on macOS.
Locally, with full Xcode selected:

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
and never automatically retries a paid call. The client reuses recognition for budget changes.
Before public use, add authenticated per-user metering in durable storage, enforce quotas
before provider calls, add a global spending circuit breaker, and set prices from observed
vision + product-search cost per successful outfit. Provider billing alerts alone are not a
hard application spending cap. See the backend's scaling notes.

Sources: [Gemini image understanding](https://ai.google.dev/gemini-api/docs/image-understanding),
[structured outputs](https://ai.google.dev/gemini-api/docs/structured-output),
[API key handling](https://ai.google.dev/gemini-api/docs/api-key),
[Apple device testing](https://developer.apple.com/help/account/basics/about-your-developer-account).
