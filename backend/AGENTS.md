# FitFind backend agent instructions

Read README.md before changing the service. Keep the existing FitFind-iOS direct `/health` and `/analyze` JSON contracts compatible unless both sides are explicitly updated.

* Node ESM, Node 22.13+. Use managed image recognition; do not train a model or hand-write image decoders.
* API keys stay server-side. Never commit `.env`, add real secrets to fixtures, print secrets, or put Gemini credentials in the iOS app.
* Do not make live paid provider calls without explicit authorization and an authorized input image. `npm test` must stay fully offline with stubbed provider calls.
* Recognition descriptions are not verified product identity, prices, inventory, shopping links or numerical match confidence. Do not fabricate those fields.
* Preserve auth, strict upload limits, image normalization, safe error responses, cancellation, provider-call ceilings and no raw-image/prompt logging.
* Budget assembly, when added, uses integer currency units and distinguishes identity evidence from visual similarity.
* Run `npm run check` and `npm test`. Report separately what was locally tested and what requires a real key/device. Do not claim deployment, live recognition or Xcode builds without verifying them.
