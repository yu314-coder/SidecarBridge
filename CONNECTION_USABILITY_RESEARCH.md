# Easier iPad-to-Mac pairing and steadier picture quality

Research and implementation: September 13, 2026. This change updates the iPad/iPhone client and the Mac app; it does not replace the installed apps or submit a release.

Subsequent release status: iOS/iPadOS [1.3 (14)](releases/ios-1.3-14.md) and macOS [1.3 (95)](releases/macos-1.3-95.md) are uploaded, VALID and in internal TestFlight. The Mac release adds a larger top-level QR/code card, Copy Code feedback, expiry countdown, and a dedicated pairing window from the menu bar. All 134 tests passed, including rendered QR decoding and readable-code checks. The verification history below records the earlier pre-upload implementation checks.

## What the research establishes

- Local discovery, network reachability, and authentication are different stages. A ready browser or a shared Wi-Fi name does not prove that an authenticated session can open. Permission-denied states need actionable help, not an endless search indicator. Apple describes the relevant Network.framework states and device-testing limits in [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- Nearby discovery can use Apple's peer-to-peer technologies through [NWParameters.includePeerToPeer](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer). This is already enabled. Scanning a QR code supplies local route hints; it cannot bypass router isolation, a firewall, or an unavailable peer.
- [VisionKit data scanning](https://developer.apple.com/videos/play/wwdc2022/10025/) provides a public QR-scanning implementation. Support and availability must be checked, camera access must be requested, and manual entry must remain available. Scanning should fill a form; connecting is a separate user action.
- Device-only Keychain credentials support reconnects without exposing a long-lived secret in settings or a QR code. [AfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly) preserves the existing on-device storage policy; it does not guarantee survival after an erase or migration to another device.
- ScreenCaptureKit exposes capture dimensions, frame intervals, and queue depth. More buffered frames use more memory; [Apple's capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) also shows updating a running stream's configuration. A requested frame interval is a target, not a promise of rendered FPS.
- Apple's [low-latency encoding guidance](https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing) supports using VideoToolbox's low-latency path without frame reordering. Those settings were already present. The app's own adaptation and connection-state handling also needed correction.

## Causes found in this checkout

1. The disconnected iPad home mixed saved-device selection, a second Connect action, code entry, detailed discovery stages, and a separate VNC connection option. This made the primary action unclear.
2. Discovery updates removed saved Macs from the visible list unless currently found or selected. That made saved pairing look lost when discovery was slow.
3. LAN authentication chose a saved credential before an explicitly entered repair code. A rejection could delete a credential before mutual authentication completed.
4. One global direct-IP cache was populated when TCP became ready, before pairing was verified. It was not associated with a specific authenticated Mac.
5. A stalled TCP/handshake candidate could repeatedly monopolize retries. The old timeout ended at TCP readiness, allowing a silent handshake to remain stuck.
6. A failed standby LAN attempt could discard queued video and report another connected event for the healthy nearby route. The model treats a real reconnect as a decoder refresh, so these unrelated events could interrupt presentation. This is a code-level finding, not a claim to have reproduced every reported device freeze.
7. Yellow memory pressure cut bitrate to 22% and capture width to 1920; red cut bitrate to 10% and width to 1280. Repeated notifications could keep postponing a transition, while brief recovery triggered another resolution change. High-FPS nearby mode also silently capped resolution at 1920 independently of the selected quality.

## New user flow

### First connection

1. Open SidecarBridge on the Mac. The temporary QR code and grouped 16-digit code are near the top.
2. On the iPad, choose **Scan Mac Code**, or enter the digits with or without dashes. A previously discovered device card is not required.
3. Check the scanned Mac name and tap **Connect**. Scanning alone never starts a connection.
4. If discovery is filtered, the QR's private addresses can be tried directly. Manual entry of the private IPv4 address is also available in a collapsed help section.
5. After mutual authentication and successful Keychain storage, the Mac appears under **Your Macs** for later one-tap connections.

### Later connections

Saved cards remain visible even when discovery has no result. Connect tries the saved, authenticated Mac's route metadata and local discovery. The app still requires a tap; opening the app, switching tabs, discovering a peer, or scanning does not grant connection consent. A connection attempt has a Cancel action and an overall 30-second timeout.

The separate Mac Screen Sharing/VNC option remains under **Other connection options**, explicitly labelled unencrypted and for trusted private networks. The encrypted app connection never silently falls back to it.

## Security properties retained or tightened

- The existing Curve25519 channel setup, encrypted packets, mutual HMAC pairing proofs, 16-digit code lifetime, server attempt limits, and random persistent Keychain credential remain in use. No cable-based authentication bypass was added.
- QR version 1 contains only the current short-lived code, Mac ID/name, bounded private IPv4 hints, and expiry. It is not a permanent credential. The parser rejects duplicates, oversized payloads, public/loopback/hostname targets, unsupported formats, and expired invitations.
- A QR or known saved route pins the expected Mac ID before a pairing proof is sent. Route hints and device names alone do not grant trust.
- Route metadata is saved per authenticated Mac only after server proof verification and credential persistence. Credentials are not stored in UserDefaults.
- Explicit repair codes take precedence over stale saved credentials on both transports. An unauthenticated rejection does not erase Keychain trust. A successful repair can replace the credential.
- Camera access is optional and initiated by the Scan button. Camera images and QR payloads are not saved or uploaded by this feature.

## Picture-quality changes

| Condition | Previous policy | Updated policy |
| --- | --- | --- |
| Moderate memory pressure | 22% bitrate; 1920-pixel cap | 80% bitrate; up to 2560 pixels |
| Critical memory pressure | 10% bitrate; 1280-pixel cap | 55% bitrate; up to 1920 pixels |
| Memory recovery | 1.5-second delay | 12 seconds of sustained recovery |
| Warning entry | 0.35-second delay | 3-second debounce plus minimum dwell |
| Critical entry | Could wait on minimum dwell | Prompt 0.1-second response |
| Nearby/high-FPS resolution | Implicit 1920 cap in regular mode | Uses selected resolution and memory cap |

Adaptive targets up to 2560 pixels; explicit 1080p/2K/4K choices remain bounded by the requested and source sizes. Existing aspect/coordinate mapping was not rewritten. Bitrate-only changes no longer request a redundant decoder keyframe. The encoder has bounded 1.5× peak-rate headroom for complex frames while preserving its average bitrate and existing queue limits.

Actual transport congestion still reduces bitrate independently. This change does not promise lossless 4K or a fixed FPS under arbitrary memory/CPU/radio conditions. Critical pressure still reduces the working surface; sustained physical-device measurements are needed before claiming a quality or FPS improvement.

## Verification

Build logs and simulator artifacts are kept under `/Volumes/D/build/SidecarBridge-usability-20260913`; no build number or App Store submission was changed.

Verified with Xcode 26.5 (17F42):

- macOS app build and all **119 tests passed**, including the existing encrypted packet/proof coverage.
- iOS device-target compilation passed; iOS simulator compilation and launch passed.
- iPad Air 13-inch simulator UI inspected: the code field and Scan action are visible, Connect is disabled until complete input, saved-device and pairing sections replace the multi-stage search UI, and no automatic connection occurred during the launch check.
- Both Info.plists passed validation; the iPad camera usage description is present. `git diff --check` passed.
- The existing installed Mac App Store app was not replaced or stopped. No App Store Connect upload, review submission, or Git push was performed.

Automated coverage includes QR parsing/expiry, strict local-address validation, per-Mac routing without secrets, explicit-code precedence, cancelled-attempt callback invalidation, active-route isolation, resolution limits, bitrate bounds, and pressure recovery policy.

Evidence: `logs/mac-verified.log`, `logs/verified-tests.xcresult`, `logs/ipad-device-verified.log`, and `ipad-connect.png` under the build folder above. The screenshot is an actual simulator capture, not an illustration. Camera scanning and successful network pairing were not simulated as proof of physical-device success.

Physical-device follow-up: scan the Mac QR; verify no connection occurs until tapping Connect; reconnect a saved Mac after relaunch and after changing its DHCP address; test denied Local Network access, invalid/expired codes, same-Wi-Fi and nearby/cable routes, and a ten-minute text/scrolling session across memory-pressure changes. Confirm keyboard, trackpad, file transfer, and background return continue to work. Simulator/build tests do not establish those results.
