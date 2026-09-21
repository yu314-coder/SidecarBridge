# Screen movement while typing

- A 44-point drag handle above the on-screen keyboard pans the Mac image vertically, including at 100% zoom.
- Existing three-finger panning is also enabled at 100% while the keyboard is open.
- The vertical travel limit includes the keyboard height and bottom clearance, so covered parts of the image can be brought above it.
- The image and input normalization continue to share `viewerOffset`; the keyboard itself stays anchored. Closing with Hide clamps the offset back to the normal zoom bounds.
- The top bar displays `streamDimensions` (received video width, height and format) with `streamFPS`, rather than the requested quality preset or a generic HiDPI label.

Verification: iOS simulator compilation succeeded (`/Volumes/D/build/SidecarBridge-keyboard-pan.log`); whitespace validation passed. Physical remote-session panning and click targeting still need testing. No upload in this change.
