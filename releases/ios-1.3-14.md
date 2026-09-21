# iOS / iPadOS 1.3 (14)

Uploaded to App Store Connect on September 13, 2026. Apple processing is **VALID**, and the internal TestFlight state is **IN_BETA_TESTING**. English What to Test notes were saved and read back successfully. External testing remains **READY_FOR_BETA_SUBMISSION**; no beta review or App Store review submission was made. macOS was not uploaded in this release; its latest verified App Store Connect build is 1.3 (94).

## What to test

- Scan the Mac QR or enter its 16-digit pairing code, then tap Connect. Saved Macs remain visible, and discovery alone never connects.
- Retry cancelled/failed connections and reconnect after switching apps. Failed standby discovery should not reset a healthy active stream.
- Open Settings → Apple Sidecar setup. USB and nearby-wireless instructions are separate from the encrypted in-app stream.
- When paired, request Displays settings on the Mac. The iPad handles acknowledgements and timeout without claiming a native session started. Finish native setup by selecting the iPad in Apple's UI.

QR display and the updated Mac setup panel require the corresponding Mac update. Follow-up: [macOS 1.3 (95)](macos-1.3-95.md) was subsequently uploaded and is VALID in internal TestFlight. Manual-code pairing and older unqualified settings acknowledgements remain supported. Mac-side bitrate/memory-pressure changes are delivered by that Mac update, not by this iOS-only upload.

## Evidence

- Archive and export succeeded using Xcode 26.5 (17F42), iPhoneOS 26.5 SDK.
- IPA signature verified; version 1.3, build 14, bundle ID `io.sidecarbridge.mac` confirmed.
- Unsupported background-audio mode is absent. No entitlement changes were added for native setup.
- The actual host build stamp `26A5388g` was retained, not replaced with a different OS version.
- Apple validation: `VERIFY SUCCEEDED with no errors`.
- Apple upload: `UPLOAD SUCCEEDED with no errors`.
- Delivery UUID: `5fcc7611-5bc2-4fa9-9311-1aec0a496e3d`.
- IPA SHA-256: `b742855bd12750977f0a477e6b3a797986ddd36a1e116e7feb023c73f6c66851`.
- Artifacts/logs: `/Volumes/D/build/SidecarBridge-ios-1.3-14-20260913`.
- Pre-release local validation: 130 macOS unit tests passed and iOS target compilation passed. Actual native USB/nearby activation and end-to-end physical-iPad testing remain unverified.

An upload or processing success is not an App Review approval or proof of physical-device behaviour.
