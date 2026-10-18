# TestFlight submission plan (iOS)

Prerequisites for getting `ios/` onto TestFlight, from a 2026-10-17 review of
the app against App Store Connect validation and Beta App Review. Three layers:
hard upload blockers, missing shipping plumbing, and ASC-side prerequisites.
Code references are to `ios/` as of that review.

## Hard blockers (upload/validation fails)

- [ ] **No app icon.** No `Assets.xcassets`, no `ASSETCATALOG_COMPILER_APPICON_NAME`
      in `Idfon.xcodeproj/project.pbxproj`, no `CFBundleIcons` in
      `Idfon/Info.plist` — nothing icon-shaped exists in the repo. Needs an
      AppIcon set including the 1024×1024 marketing icon (no alpha channel).
- [ ] **No `PrivacyInfo.xcprivacy`.** Required-reason APIs in use:
      - `UserDefaults` in 15 files → `NSPrivacyAccessedAPICategoryUserDefaults`,
        reason `CA92.1`.
      - `attributesOfItem(...)[.modificationDate]` at `Idfon/EdgeClient.swift:313`
        → `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1`
        (app-container files).
      Without the manifest this is ITMS-91053, a straight rejection since
      May 2024.

## Shipping plumbing (does not exist yet)

- [ ] **Archive → export → upload path.** `ios/build.sh` only does a device
      `build`. Need `xcodebuild archive` + `-exportArchive`
      (method `app-store-connect`) + `xcrun altool --upload-app` (or Transporter).
      Natural home: an `upload.sh` sibling of `build.sh`. After archiving,
      verify `codesign -d --entitlements` shows `aps-environment=production` —
      the distribution profile rewrites the `development` value in
      `Idfon/Idfon.entitlements` (the comment there is right), but the project
      has never gone through an archive, so confirm on the first one.
- [ ] **`CFBundleVersion` must be unique per upload.** `CURRENT_PROJECT_VERSION = 1`
      is hardcoded in the pbxproj; the upload script needs a bump step.

## App Store Connect side (not code, but blocking)

- [ ] App record for `com.idfon.ios`: name, SKU, primary language, bundle id
      registered to team `RV27HPQNMF`.
- [ ] **Privacy policy URL** — required before any external testing.
- [ ] **App Privacy answers**: mic, camera, contacts writes, on-device speech,
      peer-id diagnostics.
- [ ] **Beta App Review materials** for external TestFlight: beta description,
      beta review notes, contact email.
- [ ] **Export compliance decision.** `ITSAppUsesNonExemptEncryption` is absent,
      so every build sits in "Missing Compliance". The content is Noise/QUIC
      message encryption (iroh) — not ancillary-to-OS crypto, so the honest
      answer is "uses non-exempt encryption", which means the ASC answer plus
      an annual BIS self-classification report. Decide before the first upload;
      this is a legal call, not a code one.

## Review-risk items — checked, currently clean

- Usage-description strings present and purpose-matched: camera, mic, contacts,
  speech, local network. No photo-picker, Face ID, Bluetooth, or ATT APIs, so
  no missing keys found.
- `SFSpeechRecognizer` is on-device-only (`requiresOnDeviceRecognition = true`,
  `Idfon/OnDeviceVoice.swift`) — no "audio sent to Apple" disclosure problem.
- No `value(forKey:)` / `NSClassFromString` / dynamic selector plumbing (the
  private-API class of failure).
- `Idfon/Automation.swift` is launch-argument gated — invisible to reviewers.
- VoIP-push accounting is the biggest *behavioral* rejection risk (Guideline
  2.5.15: VoIP pushes must be calls). The "every push ends in a reported call"
  rule (commit b23d377) covers it — the shipping build must keep it.

## Smaller decisions

- **iPad**: `TARGETED_DEVICE_FAMILY = "1,2"` with an iPhone-only UI means ASC
  demands iPad screenshots and, on current iPadOS, multitasking compliance
  (`UIRequiresFullScreen` is deprecated in the Xcode 27 SDK). Simplest: set
  device family to `1`.
- **Pre-submit residue**: run the rules in `edge-deploy-checklist.md` before
  archiving — no test `-edgeurl`/`-edgeticket`, staging edge, or test APNs
  `.p8` in the shipping build (issue #54's half).

## Not covered here

ASC account state (agreements, app record) and production APNs certificates on
the edge live outside the repo. The binary was not scanned for private-API
symbol traces the way `device.sh` greps `strings` for delegate selectors.
