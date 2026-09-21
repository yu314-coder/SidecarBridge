# Cursor-following keyboard viewport

Replaces the manual drag strip with edge-triggered viewport movement while the custom keyboard is visible. The existing normalized cursor feedback drives panning; the cursor itself is not moved by this policy. A 36-point maximum inset gives a quiet central area. The view eases toward visibility in 30 Hz steps; Reduce Motion applies the correction immediately.

Both the video and remote-input coordinate conversion use the same `viewerOffset`. There is no independent SwiftUI presentation animation. The loop runs only while the keyboard is visible and restarts on viewport size changes. Pinch and normal input gesture meanings are unchanged.

Tests: three policy tests passed (quiet zone, convergence without overshoot, return pan at upper edge). iOS simulator build passed and was installed on the existing iPad simulator. Real keyboard-open cursor tracking/click alignment needs physical testing. No TestFlight upload in this change.

Logs: `/Volumes/D/build/SidecarBridge-cursor-follow-tests.log` and `/Volumes/D/build/SidecarBridge-cursor-follow-build.log`.
