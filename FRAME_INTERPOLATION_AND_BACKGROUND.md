# Live interpolation and background viewer experiment

## Test on a real connection

In Settings, unlock Developer options by tapping the version seven times.
Enable **Live frame interpolation (experimental)** during an authenticated
Mac connection. The switch defaults to off each launch; it does not modify
pairing, input coordinates, capture settings, or the Mac's encoder.

Start with **1080p, 60 FPS** and a 120 Hz iPad Pro. On a 60 Hz device, a
30 FPS input can instead exercise 30-to-60 interpolation. The iPad uses
VideoToolbox's low-latency frame processor, not the game-oriented MetalFX
interpolator that requires depth and renderer motion-vector textures.

- Requires iOS/iPadOS 26+ and runtime processor support. The simulator uses
  ordinary playback. Apple's configuration can still reject a particular
  input size or pixel format; this is reported and original playback resumes.
- Inputs larger than 1080p bypass interpolation. Native 2K/4K is preserved,
  never silently downscaled. This is not an upscaling switch.
- Decoding and model initialization run off the UI thread. There is one
  processing pair, one newest waiting decoded frame, at most twelve
  asynchronous compressed decoder submissions and a bounded destination pool.
- A short decoder burst no longer disables the experiment. The viewer keeps
  its last good image, requests a fresh IDR from the Mac, mirrors that recovery
  keyframe through ordinary playback, and resumes interpolation automatically.
  The user does not need to toggle the setting to recover.
- Late output is discarded, timestamps cannot go backwards, and generation
  tokens prevent old tasks from repainting after a toggle, reconnect, or
  background transition. Thermal pressure bypasses generation. A memory
  warning switches the experiment off.
- The original compressed playback path is used during PiP. No generated
  frame changes pointer mapping or remote input messages.

The diagnostic shows **output submissions**, generated submissions, processor
time, and a rolling 1% low computed from the mean of the slowest 1% of the
last 600 submission intervals. These are not measurements of physical panel
scanout, capture FPS, or network throughput. The main received-FPS counter
remains unchanged. Compare motion, readable text, and control latency, not
just the generated-frame number. No physical-device performance gain has
been verified yet.

Synthetic frames can introduce artifacts around small text and the Mac's
captured cursor. Remote input itself is unchanged. Leave this off if the
visual artifacts or additional frame-pair latency are distracting.

## Background changes

The prior target lacked `UIBackgroundModes = [audio]` and an active playback
audio session, despite already creating a sample-buffer PiP controller.
Apple uses this background-mode value for **Audio, AirPlay, and Picture in
Picture**, including video playback. The live viewer now configures a mixing
playback session when video starts and releases it when streaming stops.
There is no silent-audio loop, fake VoIP mode, or other keepalive workaround.

When live PiP survives an app switch, returning preserves the decoder. The
new `viewer-foreground-live` control message restores foreground cadence on
the Mac without unnecessarily restarting ScreenCaptureKit. A stale or lost
session still follows keyframe/reset and authenticated-reconnect recovery.
The feature is negotiated: older Mac companions keep their existing
foreground-resume message and behavior.
Closing PiP explicitly cancels pending auto-restart attempts. iPadOS may
suspend the app when PiP is closed or unavailable; an invisible indefinite
connection is not promised. Pairing and the user's connection intent remain
available for automatic resume.

## Required physical-device checks before release

1. Compare interpolation off/on while scrolling text, dragging windows and
   playing moving video at 1080p60 on a 120 Hz device. Record input latency,
   received/output FPS, generated frames, processor time, and memory.
2. Repeat at native 4K: the status must explain bypass, with resolution and
   keyboard/pointer control unchanged.
3. Toggle repeatedly, switch capture resolution, reconnect, and test memory
   pressure. No old output may reappear; original video must continue.
4. With background viewing enabled, switch to another app for 30 seconds and
   5 minutes. Confirm the PiP picture actually updates and returning requires
   no Connect button. Repeat on direct LAN and nearby P2P.
5. Close PiP, wait for possible suspension, then return. Check recovery and
   fresh video. Check permission alerts and Control Center do not reconnect.
6. Turn automatic background viewing off, stop streaming, and disconnect:
   verify PiP closes and no background playback work persists.

## Local validation (2026-09-22)

- Unsigned iOS-device and iOS-simulator Debug builds succeeded.
- macOS build and 172 unit tests passed, including resolution/cadence guards
  and healthy-versus-stale PiP resume policy.
- The installed Mac runtime reports interpolation support and accepts
  1280×720 and 1920×1080 configurations with NV12 video-range buffers. This
  is a capability query, not a performance benchmark or iPad validation.
- A physical iPad was paired but was not used for an automated live connection
  test. Actual frame-generation quality,
  sustained display timing, and long-running background behavior remain
  device-test items. The automatic decoder-recovery correction was uploaded as
  iOS/iPadOS 1.4 (2), processed `VALID`, and entered internal TestFlight. No App
  Store review submission was performed.

## App Review notes (draft; attach a real recording before submitting)

SidecarBridge uses the Audio, AirPlay, and Picture in Picture background mode
for its user-visible live remote-screen video viewer. It does not play silent
audio to keep the process alive. To test, install the Mac companion, pair the
iPad, start the remote screen, enable Settings > Background viewer, then use
Start PiP Now and navigate to the Home Screen or another app. The floating
video continues showing changes made on the Mac. Closing PiP ends background
viewing. A physical-device screen recording of these steps is required before
claiming this behavior to App Review, especially given the prior 2.5.4 query.

## Apple references

- [Low-latency frame interpolation](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration)
- [Machine-learning video effects, WWDC25](https://developer.apple.com/videos/play/wwdc2025/300/)
- [Custom player Picture in Picture](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)
- [Playback session and background capability](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)
- [iOS and iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
