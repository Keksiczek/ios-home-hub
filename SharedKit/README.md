# SharedKit + Share Extension (Epic 2)

## What lives where

```
SharedKit/                   # Compiled into BOTH HomeHub and HomeHubShareExtension
  SharedStorage.swift        # App Group container layout, SHA-256, path safety
  SharePayload.swift         # SharePayload + ShareRequest + SharePayloadStore
  SharedKitLog.swift         # os.Logger categories shared across processes

ShareExtension/              # Compiled into HomeHubShareExtension only
  ShareViewController.swift  # UIKit/SwiftUI host with status UI
  ShareItemExtractor.swift   # NSItemProvider → SharePayload normaliser
  Info.plist                 # NSExtension activation rules + principal class
  ShareExtension.entitlements

HomeHub/Services/KnowledgeBase/
  ShareInboxBridge.swift     # ShareRequest → IngestJob conversion (host-only)
  KnowledgeBaseService.swift # Drains the bridge on bootstrap + scenePhase
  IngestPipeline.swift       # Picks up the IngestJob and runs the pipeline
```

## End-to-end flow

1. User taps share in Safari / Files / any host app.
2. iOS shows HomeHub if the content matches `NSExtensionActivationRule`
   (URL with web URL, web page, plain text, or attachment ≤ 10).
3. `ShareViewController.viewDidAppear` constructs `SharedStorage` (via
   the App Group entitlement) and a `ShareItemExtractor`.
4. The extractor walks `extensionContext.inputItems`, classifies each
   `NSItemProvider` (PDF → URL → text → file URL — most specific
   first), copies file payloads into `<container>/inbox/` with a
   UUID-prefixed name, computes SHA-256, and writes:
   - `<container>/kb/index/share-payloads.json` (append `SharePayload`)
   - `<container>/kb/index/share-requests.json` (append `ShareRequest`
     with `status = .stored`, `action = saveToKnowledgeBase`)
5. UI flashes "Uloženo" for 600 ms; extension calls
   `extensionContext.completeRequest(returningItems: nil)` and dies.
6. Next time HomeHub is launched / foregrounded, `KnowledgeBaseService`:
   1. calls `ShareInboxBridge.drain()` — converts every pending
      `ShareRequest` into an `IngestJob` (text/URL payloads are
      materialised as `.txt` files in `kb/files/`), flips the
      request status to `.consumedByApp`.
   2. calls `IngestScheduler.drainForegroundIfPending()` — runs the
      Knowledge Base pipeline (parsing → chunking → embedding → indexing).
   3. `BGProcessingTask` picks up the slack if the user backgrounds
      the app mid-drain.

## Why no shared framework target

Sharing files between targets via xcodegen `sources:` is simpler
than introducing a Swift Package or framework target:
- No new module imports to update.
- No Swift access-modifier surface to maintain (`public`/`internal`).
- The `.appex` binary stays small (~150 KB instead of pulling in
  HomeHub's MLX + WhisperKit + transformer dependencies).
- The on-disk JSON contract is the only cross-target boundary,
  which is exactly what we want — no in-memory type sharing.

The trade-off: `SharedStorage` and `SharePayload` are compiled twice
(once per target). They MUST stay binary-compatible with their JSON
representation, but that's a single-file contract, not a runtime
ABI concern.

## Activation rules (`ShareExtension/Info.plist`)

```xml
<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
<integer>1</integer>
<key>NSExtensionActivationSupportsWebPageWithMaxCount</key>
<integer>1</integer>
<key>NSExtensionActivationSupportsText</key>
<true/>
<key>NSExtensionActivationSupportsAttachmentsWithMaxCount</key>
<integer>10</integer>
```

We deliberately omit:
- `NSExtensionActivationSupportsImageWithMaxCount` — image OCR is
  out of scope for the v1 KB pipeline.
- `NSExtensionActivationSupportsMovieWithMaxCount` — video would
  blow the 64 MB cap and we can't extract anything useful yet.
- `NSExtensionActivationSupportsFileWithMaxCount` — covered by the
  `Attachments` rule which iOS treats as a generic file passthrough.

## Manual test checklist

1. **Run** the host app once on device/simulator so iOS registers the
   App Group container.
2. **URL share** — Safari → tap share → HomeHub. Open the host app,
   go to Settings → Developer → Knowledge Base. The share appears
   under "Sdílené" and (after the bridge fires) flips to
   `consumedByApp`; an ingest job appears under "Joby".
3. **Text share** — long-press text in Notes → Share → HomeHub.
   Same observation as above.
4. **PDF share** — share a PDF from Files → HomeHub. Verify the
   Document appears under "Dokumenty" with status `indexed` after
   the pipeline finishes.
5. **Big file** — share a >64 MB PDF. The extension UI shows the
   error. Nothing is added to the inbox.
6. **App not launched** — share while the host app is fully killed.
   Open the app: bootstrap drains the inbox automatically.

## Apple Developer Console

Both the host app and the Share Extension need the App Group
`group.cz.keksiczek.homehub.shared` enabled in their App IDs (Apple
Developer → Certificates, Identifiers & Profiles → Identifiers →
each identifier → App Groups).

For local "personal team" signing, App Groups work without a paid
developer account on simulator and on a registered device, but
the group identifier must be unique to your team.
