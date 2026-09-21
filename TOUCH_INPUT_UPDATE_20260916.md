# Finger, Pencil, and custom keyboard usability

## Changes
- Finger taps and hold-drags act at the existing remote cursor instead of jumping to the finger's absolute screen position. Sliding remains relative, like a trackpad.
- Rate-limited finger movement accumulates rather than discarding intermediate deltas; gesture completion flushes the remainder and cancellation clears it.
- Finger hold-to-drag waits 0.35 seconds to reduce accidental drags.
- Pencil hold-drag uses absolute screen coordinates consistently. Pencil pan begins at the original contact location.
- Custom keyboard keys, modifiers, page selectors, and bottom controls have 44-point minimum heights. The keyboard panel accommodates the taller layout, with scrolling on smaller viewports.

Magic Keyboard/external-pointer handling and display coordinate transforms are unchanged. Video transport, pairing, and clipboard policy are unchanged.

## Verification
- 154 selected macOS tests passed, including two new movement-accumulation tests and keyboard layout rendering. The existing OCR pairing-preview test was excluded due to its previously observed Vision stall on this host.
- iPad simulator build succeeded; installed and launched on the existing iPad Pro 13-inch (M5) simulator.
- Inspected rendered Standard and Special keyboard pages at 980-point width; no clipped bottom controls.
- Physical finger/Pencil interaction and a live remote session still require device testing. Simulator launch and component renders do not prove physical-input behavior.
- No App Store Connect upload, Git push, or installed Mac app replacement in this update.

Evidence: `/Volumes/D/build/SidecarBridge-touch-20260916.xcresult`, `/Volumes/D/build/SidecarBridge-touch-ipad-20260916.log`, and `/Volumes/D/build/SidecarBridge-touch-previews-20260916/`.

## Follow-up: fit within the available window
- The panel now uses at most half the available height (capped at 540 points) and never forces a 280-point minimum width beyond the window.
- Mode selectors and Clear/Hide stay outside the scrollable key area. Special keys and shortcuts wrap into adaptive columns on narrow windows.
- Both pages were size-tested at 1366x1024, 1024x1366, 744x1133, 375x700, and 812x375 points. Two layout tests passed and the iPad simulator build succeeded.
- Hosted-view snapshots were used because ImageRenderer did not render ScrollView contents. Inspected the large landscape Standard and narrow Special snapshots. On small windows, keys scroll rather than shrinking below their 44-point row height.
- Evidence: `/Volumes/D/build/SidecarBridge-fit-hosted-20260916.xcresult` and `/Volumes/D/build/SidecarBridge-fit-hosted-previews/`. These are component previews, not physical iPad screenshots.
- Reference: https://support.anydesk.com/anydesk-for-ios-ipados-tvos documents separate Standard/Special modes. DeskIn's public documentation did not establish exact keyboard sizing; no pixel-identical claim is made.
