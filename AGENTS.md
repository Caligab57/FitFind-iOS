# FitFind iOS

Native SwiftUI app in FitFind/; the Node recognition service is in backend/ in this same repository.
Read README.md before changes. Target iOS 16+, Swift 5.9, Xcode 15+.
For backend changes, read backend/AGENTS.md and backend/README.md; run npm run check and npm test from backend/.
The backend runs separately on a Mac/server and is not bundled into the iOS app.
Keep provider keys out of the app and Git. Store the local development access token in Keychain.
Budget amounts are integer USD cents; allocations are targets, never quoted product prices.
Never invent product links, brand identity, confidence percentages, or live results.
Run swift test for domain changes and xcodebuild for app changes when Xcode is available.
Do not describe recognition as tested live without testing an authorized image with an actual provider key.
