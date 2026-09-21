# Native-like remote keyboard

The custom keyboard keeps the remote Command, Option, Control, Tab, language and special-key controls, without opening a second system keyboard.

- Compact phone dock: 336 points instead of 400; 44-point letter keys instead of 56.
- Staggered QWERTY rows, wider Return, globe language control and less outer framing.
- Touch-down highlight and character preview; normal Button release/cancellation semantics remain intact.
- System selection feedback requested on touch-down on iOS. Availability depends on device hardware/system settings; this is not Apple's private keyboard implementation.
- No changes to pointer alignment or the remote input protocol.

## Composition review

DesignSignalPacket.composition_state: staggered keyboard grid; letter block is the primary anchor, space/return the secondary anchor, remote modifiers and mode controls tertiary. Six-point inner margin plus parent inset; reduced double framing. Portrait phone and tablet simulator screenshots inspected without key clipping.

## Verification

- iOS simulator build succeeded; six layout/mapping tests passed.
- Existing iPhone 17 Pro and iPad Pro simulators installed and launched with the keyboard-layout preview fixture (not a live Mac connection).
- Screenshots: `/Volumes/D/build/keyboard-native-phone.png` and `/Volumes/D/build/keyboard-native-ipad.png`.
- Physical-device touch feel, haptics, and end-to-end remote typing still need user testing. Not uploaded to App Store Connect in this task.
