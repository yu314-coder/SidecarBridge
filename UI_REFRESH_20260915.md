# Workspace UI refresh

Mac: replaced the single long dashboard with Connect, Display, Transfers and Settings workspaces. Pairing remains the primary action on Connect. Existing controls are retained in their relevant workspace. The header is more compact and the selected navigation item has a filled background and accessibility selected state.

iPad: compact brand header, a clear connection heading, a two-column saved-device/pairing workspace at regular widths, and a stacked layout at compact or accessibility text sizes. First-time compact layouts put pairing first. The bottom bar highlights the selected tab with a filled shape as well as color. No automatic connection, key dispatch, cursor mapping or video configuration was changed.

## Composition signal

```json
{
  "composition_state": {
    "grid": "centered modular workspace; two equal columns on regular-width iPad",
    "primary_anchor": "pairing or saved-device connection action",
    "secondary_anchor": "session status",
    "tertiary_elements": ["brand header", "navigation", "alternative routes"],
    "spacing_points": {"column_gap": 18, "section_gap": 24},
    "negative_space": "bounded gutters and section spacing, no fixed empty hero",
    "compact_fallback": "single column; existing controls remain reachable by scrolling"
  }
}
```

Build/test logs are under `/Volumes/D/build/SidecarBridge-ui-*-20260915.log`. No upload or App Review submission was requested for this UI pass.

Verification: Mac and iPad simulator targets compile. The 150-test Mac run had one QR-cache object-identity assertion failure; that test passed on a separate rerun without code changes to the cache. iPad Pro 13-inch (M5), an existing simulator, was used to inspect the actual home screen and correct a truncated empty-state hint. The installed Mac app was not replaced. Physical-device connection and full Mac-window interaction checks are not claimed.
