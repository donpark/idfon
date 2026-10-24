# TestFlight submission plan (iOS)

Prerequisites for getting `ios/` onto TestFlight, from a 2026-10-17 review of
the app against App Store Connect validation and Beta App Review. Three layers:
hard upload blockers, missing shipping plumbing, and ASC-side prerequisites.
Code references are to `ios/` as of that review.

## Hard blockers (upload/validation fails)

- [x] **App icon — done (2026-10-19).** AppIcon set + 1024×1024 marketing
      icon (RGB, no alpha channel) shipped, `ASSETCATALOG_COMPILER_APPICON_NAME`
      set, `CFBundleIconName` in `Idfon/Info.plist` — see `app-icon.md`.
- [x] **`PrivacyInfo.xcprivacy` — done (2026-10-21).**
      `ios/Idfon/PrivacyInfo.xcprivacy` declares the two required-reason API
      categories below (`CA92.1`, `C617.1`); the synchronized folder group
      pulls it into the target, verified present in the built bundle. Without
      the manifest this is ITMS-91053, a straight rejection since May 2024.
      Required-reason APIs in use (re-verified 2026-10-21 — still exactly
      these two):
      - `UserDefaults` in 16 files → `NSPrivacyAccessedAPICategoryUserDefaults`,
        reason `CA92.1`.
      - `attributesOfItem(...)[.modificationDate]` at `Idfon/EdgeClient.swift:313`
        → `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1`
        (app-container files).

## How to ship an app update

    pnpm ios ship      # = ios/upload.sh (the whole path):
                       # build-number bump → archive → ship-hygiene gates →
                       # CLI export for App Store Connect → gate the IPA →
                       # upload

- Upload runs via `xcrun altool` when `APPLE_ID` +
  `APPLE_APP_SPECIFIC_PASSWORD` are set; otherwise the run stops at
  `ios/build/export/Idfon.ipa` — upload that file from Transporter.
- **Ship only the CLI-exported IPA above — never the Xcode Organizer
  export.** Organizer's Distribute keeps the entitlements file's
  `development` value verbatim: App Store Connect rejects it (90046) and, if
  one slips through, the build mints sandbox push tokens and nothing rings
  (the locked-phone wake saga). `upload.sh` gates on `aps-environment =
  production` in the extracted IPA for exactly this reason.
- **Commit the `CURRENT_PROJECT_VERSION` bump** the script makes in
  `ios/Idfon.xcodeproj/project.pbxproj` together with what it ships —
  TestFlight rejects reused build numbers.
- `pnpm ios archive` stops after archiving (gates + Organizer staging,
  no export/upload). Handy for inspecting the `.xcarchive`, but do not
  Distribute from Organizer — see the entitlements rule above.

## Shipping plumbing

- [x] **Archive → export → upload path — done (2026-10-21).** `ios/upload.sh`
      (sibling of `build.sh`): build-number bump → `xcodebuild archive` →
      gates → `-exportArchive` (method `app-store-connect`, team
      `RV27HPQNMF`) → `xcrun altool --upload-app` when
      `APPLE_ID`+`APPLE_APP_SPECIFIC_PASSWORD` are set, else the IPA is left
      for Transporter. First archive+export ran
      2026-10-21: export re-signs with the distribution profile and the
      archived IPA shows `aps-environment=production` / `get-task-allow=false`
      — the plan's open first-archive question is answered; `upload.sh` gates
      on it. The `.xcarchive` lands outside Organizer's
      `~/Library/Developer/Xcode/Archives`; `pnpm ios archive` stages it
      there. `pnpm ios ship` is the alias for the full path (added 2026-10-25).
- [x] **`CFBundleVersion` must be unique per upload — done (2026-10-21).**
      `upload.sh` bumps `CURRENT_PROJECT_VERSION` (pbxproj, all configs) on
      every run. On the manual Xcode path, bump Build (target → General) by
      hand before archiving — and commit the bump either way.

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

- **iPad — done (2026-10-21):** `TARGETED_DEVICE_FAMILY = "1"` (all configs);
  verified `UIDeviceFamily = [1]` in the built Info.plist, so ASC no longer
  demands iPad screenshots or multitasking compliance.
- **Pre-submit residue — gated (2026-10-21):** `upload.sh` scans the archived
  binary for rig markers (`e2etoken`, sandbox APNs URL, `:8090`, RFC1918 IPs)
  and for a bundled `.p8`, and fails hard. For the manual first archive, run
  the rules in `edge-deploy-checklist.md` by hand first (issue #54's half).

## Not covered here

ASC account state (agreements, app record) and production APNs certificates on
the edge live outside the repo. The binary was not scanned for private-API
symbol traces the way `device.sh` greps `strings` for delegate selectors.
