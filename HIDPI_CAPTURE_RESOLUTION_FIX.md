# Native capture resolution

The connected BenQ MA270U reports 3840 x 2160 pixels with a 1920 x 1080 logical desktop. Capture initialization previously used SCDisplay dimensions directly and capped scaling at 1. The source now uses SCContentFilter.contentRect multiplied by pointPixelScale, retaining pixel dimensions for later configuration changes.

Auto may request up to 3840 pixels (bounded by the viewer's advertised width). Explicit 2K/4K choices are no longer capped by that viewer-width hint. Memory warning retains a 2560 cap; critical pressure retains 1920; normal recovery restores the chosen target. Source-size limits remain, so a true 1080p source is not upscaled to pretend it contains 4K detail.

Reference: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale

Verification: system_profiler confirmed the connected display's physical and logical resolutions. Eleven resolution-policy and settings-matrix tests passed after updating the two old Auto-cap expectations. Mac test build succeeded. Live captured pixels on a physical iPad have not been verified, and the installed Mac app was not replaced. No upload in this change.

Log: `/Volumes/D/build/SidecarBridge-resolution-tests-final.log`.
