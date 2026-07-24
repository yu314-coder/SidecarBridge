# SidecarBridge Accessibility

This document records the accessibility implementation and the conservative App Store Connect declaration for SidecarBridge build 3.

## Common tasks

The common tasks evaluated for iPhone and iPad are:

1. Launch the app and understand discovery status.
2. Allow Local Network access or open Settings when permission is denied.
3. Find and pair with a Mac.
4. Choose and start In-App Display.
5. Read connection and remote-input status.
6. Open viewer controls, zoom, click, change viewer settings, and stop streaming.
7. Send or share a file.
8. Configure background Picture in Picture.
9. On iPad only, select and explicitly open System Sidecar.

## Implemented support

- **Dark Interface:** Every common task uses the app's dark interface.
- **Differentiate Without Color Alone:** Connection, permission, selection, and error states include text and distinct symbols in addition to color. The selected display mode uses a checked shape.
- **Reduced Motion:** The discovery pulse, viewer drawer transitions, and click feedback stop or become immediate when the system Reduce Motion setting is enabled.
- **Larger Text foundations:** Text uses Dynamic Type styles; compact layouts fall back to vertical arrangements; the dashboard and viewer drawer scroll; status and descriptive text avoid fixed truncation.
- **Assistive technology labels:** Decorative images are hidden, status tiles expose combined labels and values, icon-only viewer controls have explicit names, and the remote screen exposes named click actions and adjustable zoom.
- **Sufficient Contrast foundations:** Essential text uses high-opacity light text on the dark interface, while state text is paired with symbols and labels.

## App Store Connect declaration

The features that can be declared from implementation and build verification are:

- Dark Interface
- Differentiate Without Color Alone
- Reduced Motion

Do not declare these until their required device-level common-task tests are completed:

- VoiceOver
- Voice Control
- Larger Text
- Sufficient Contrast

Do not declare Captions or Audio Descriptions. SidecarBridge does not present authored video dialogue or an audio program for which synchronized captions or described narration are provided.

The remote Mac screen is pixel content rather than a semantic accessibility tree. The surrounding controls are labeled, but that does not make every remote Mac task independently completable with VoiceOver or Voice Control. This is why the current declaration remains conservative.

## Manual checks before expanding the declaration

On both iPhone and iPad:

1. Complete every common task at 200% or the largest Dynamic Type size and check for overlap or severe truncation.
2. Complete every common task using only VoiceOver.
3. Complete every common task using only Voice Control with Show Names and Show Numbers.
4. Enable Bold Text, Increase Contrast, and Reduce Transparency, then verify text contrast with Accessibility Inspector.
5. Enable Grayscale and confirm every status and selection remains understandable.
6. Enable Reduce Motion and confirm there is no ongoing pulse, sliding drawer transition, or scaling click animation.
