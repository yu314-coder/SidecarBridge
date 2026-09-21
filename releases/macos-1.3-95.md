# macOS 1.3 (95)

Uploaded September 13, 2026. Use with iOS/iPadOS [1.3 (14)](ios-1.3-14.md). Apple validation and upload succeeded with no errors. App Store Connect processing is **VALID** and internal TestFlight is **IN_BETA_TESTING**. External testing remains **READY_FOR_BETA_SUBMISSION**; no beta review or App Store review submission was made.

## Easier pairing

- Pairing is directly below the Mac window header, before connection status and other controls.
- A large QR code and four readable groups expose the complete 16-digit code. Copy Code shows confirmation; the expiry countdown explains when the temporary code refreshes.
- Enlarge QR opens a dedicated pairing window. The menu-bar item **Show Pairing QR and Code** also opens it, with Command-Shift-P as its shortcut.
- On iPad/iPhone, choose **Scan Mac Code**, verify the Mac, then tap **Connect**. Scanning fills the form; it never authorizes an automatic connection.
- Manual entry remains available with or without dashes. Existing saved trust and five-minute first-pairing codes retain the same authentication policy.
- Unicode Mac names are bounded by UTF-8 byte length so the Mac cannot generate an invitation rejected by the iOS parser.
- Includes the previously local Mac connection-route, steadier picture-quality adaptation, and public Apple Sidecar setup-guide changes. Native Sidecar still opens outside SidecarBridge and requires choosing the iPad in Apple's UI.

## Verification

- All **134 tests passed**, including decoding the generated QR back to its exact invitation and OCR checks for all four code groups at 704- and 900-point card widths.
- Both SwiftUI-rendered layouts were inspected. Images use a sample code, not a real authorized device. They are rendered component tests, not an end-to-end physical-device session.
- Final archive/export succeeded with release Xcode **26.5 (17F42)** and **macOS 26.5 SDK**; the app includes **arm64 and x86_64**.
- Exported package signature and enclosed app signature verified; version **1.3 (95)** confirmed. App Sandbox and the existing minimum entitlements are retained.
- The actual host build stamp `26A5388g` is retained, not replaced with another OS version.
- Package SHA-256: `30f140b3859960c347af30e5e5b87c1069c7f543c24469f0f1d5280cca0b2e94`.
- Apple validation: `VERIFY SUCCEEDED with no errors`; upload: `UPLOAD SUCCEEDED with no errors`.
- Delivery UUID: `4a7c94c3-9800-4061-95be-718cacd852cc`.
- English TestFlight What to Test notes were saved and read back successfully; processing and notes evidence is in `asc-verified.log` under the artifact directory.
- Artifacts: `/Volumes/D/build/SidecarBridge-mac-1.3-95-20260913`.
- Test result: `/Volumes/D/build/SidecarBridge-usability-20260913/logs/mac-pairing-wrap-tests.xcresult`.
- Final previews: `final-previews/23DB7F6C-3B1E-4EDA-A074-C17BA3BE6EC0.png` (900 pt) and `final-previews/B1B61441-98E7-4989-B680-95C411E2148B.png` (704 pt), under the artifact directory.

The installed Mac app was not replaced or stopped. Physical-iPad camera scanning, pairing, video and input still need an end-to-end device test. No Git push or App Store review submission was performed.
