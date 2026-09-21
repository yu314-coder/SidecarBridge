# Native Apple Sidecar: supported setup, not an embedded stream

Research and implementation: September 13, 2026. The implementation was first verified locally without replacing installed apps. iOS/iPadOS [1.3 (14)](releases/ios-1.3-14.md) and macOS [1.3 (95)](releases/macos-1.3-95.md) have since been uploaded, processed VALID and enabled for internal TestFlight. No Git push or App Store review submission was performed.

## What is actually possible

[Apple's Sidecar guide](https://support.apple.com/en-us/102597) describes a user-selected display session in Apple's own iPad interface. It supports USB and nearby wireless. Both devices need the same Apple Account with two-factor authentication; wireless needs proximity, Wi-Fi/Bluetooth/Handoff, and no connection sharing. USB needs trust. Internet access or a charging indicator does not establish Sidecar readiness.

Apple supports an iPad keyboard in native Sidecar. Its pointing options are a Mac-connected mouse/trackpad or Apple Pencil. SidecarBridge's iPad trackpad/touch controls remain part of its separate encrypted In-App Display.

Review of Apple's documentation and the Xcode 26.5 public AppKit/UIKit headers did not reveal a public API to enumerate Sidecar peers, force the wired transport, start a native session, or embed its output in a third-party iPad view. This is a supported-integration boundary, not a claim that private reverse engineering is technically impossible. [App Review 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements) requires public APIs. No private Sidecar framework, Apple Events exception, injected helper, or new entitlement was added.

## User flow

- iPad: **Settings → Apple Sidecar setup**, or **Other connection options → Apple Sidecar** before pairing. The guide lives in Settings navigation, not a popup.
- Mac: **Set Up Apple Sidecar**, then the USB/nearby checklist and **Open Displays Settings**.
- Choose the instructions for the intended route. This does not claim to detect the actual cable route, trust state, Apple Account, device compatibility, or native availability.
- If already paired with the Mac app, the iPad can send **Open Displays on Mac** over the existing authenticated channel. Otherwise, follow the manual Mac steps; native Sidecar does not require either companion app.
- Select the iPad in the Mac's Displays/Add Display or Screen Mirroring controls. A user can return to the existing in-app screen to make this selection remotely.
- The native display belongs to Apple and opens outside SidecarBridge. There is no automatic VNC or app-stream substitution labelled as native Sidecar.

## Bugs and misleading behaviour removed

The old Mac handler unconditionally sent `sidecar-settings-opened`, without checking NSWorkspace's return value. The iPad did not handle that reply and could remain on “Requesting System Sidecar”. Old statuses could also claim native success based solely on a message.

The updated request carries a UUID and a bounded USB/nearby instruction preference. Success/failure replies echo the UUID. The iPad accepts replies only during its current request; a disconnect, a return to the app viewer, or timeout invalidates it. The older unqualified settings acknowledgement remains supported while a request is pending. An eight-second timeout gives manual steps instead of an endless spinner. No phase claims native connection success.

NSWorkspace uses a best-effort Displays URL, falling back to the System Settings application if that URL is rejected. A `true` result means Launch Services accepted an open request, not that the correct pane appeared or Sidecar connected. Missing/blocked handlers give manual instructions. The old always-empty “reachable Sidecar devices” facade was removed.

The old saved “System Sidecar mode” no longer leaves an explicitly authenticated app connection waiting for a different session. **Connect** means encrypted In-App Display. Native setup is a separate user action. No discovery result, app launch, guide opening, or settings acknowledgement grants connection consent.

Opening setup leaves capture, input, saved Keychain trust and the app stream intact. Returning from the guide does not rebuild an already-running video session. The existing OS-controlled background lifecycle still applies when switching to Apple's app; this is not an unlimited-background execution workaround.

## Verification and remaining limits

Tests cover request parsing, both routes, wrong/stale/legacy replies, failure handling, request-specific timeout, reset after disconnect, and rejection of legacy native-success claims. The NSWorkspace wrapper is tested with injected handlers: accepted pane, application fallback, missing application, and rejected open request. These tests do not launch system settings or a native session.

Latest local verification: macOS build and **130 unit tests passed**; physical-iOS-target compilation passed with Xcode 26.5. Logs are in `/Volumes/D/build/SidecarBridge-usability-20260913/logs/` (`mac-native-sidecar-final.log`, `ipad-native-sidecar-final.log`, `native-sidecar-final-tests.xcresult`). Both Info.plists and the unchanged Mac entitlements passed validation; `git diff --check` passed.

A read-only NSWorkspace probe on this Mac resolved both the Displays URL handler and the Settings bundle to `/System/Applications/System Settings.app`. The probe did not open settings or start Sidecar. The new Settings guide compiled for iPad but was not interactively exercised on a physical device.

Still required on actual devices: follow USB and nearby setup; confirm the intended iPad appears in Apple Displays; select it; verify Apple's native session and its input differences; switch back to the in-app viewer and check video/control recovery. Simulator/compile/unit results do not establish those outcomes. Actual FPS/quality in native Sidecar is controlled by Apple, not this setup guide.
