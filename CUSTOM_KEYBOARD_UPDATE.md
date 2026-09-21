# Custom-only on-screen keyboard

## Layout revision — iOS/iPadOS 1.3 (16)

The panel now uses the available viewer width (up to 1100 points), defaults to Standard, and separates basic typing from the Special page. Rectangular keys replace the cramped system-styled capsules. Function keys use two rows and special navigation/shortcut rows stay visible without horizontal scrolling. Compact windows retain vertical scrolling. No cursor mapping or key-event transport was changed.

148 automated tests passed, including rendering both complete pages at landscape width and checking that they fit the 430-point panel. Rendered component previews are in `/Volumes/D/build/SidecarBridge-keyboard16-previews4`. These are SwiftUI component renders on macOS, not a physical iPad session. Rotation, touch input and keyboard coexistence still need device testing.

## Initial implementation record (before upload)

The viewer's Show On-Screen Keyboard action opens only the custom SwiftUI keyboard. A zero-sized UIKit input view suppresses the default iPad keyboard while this panel is visible, including when hardware keyboard detection is active. Outside the panel, the existing hardware-keyboard input-mode path is retained.

The custom panel includes QWERTY letters, numbers, a symbols page, Shift/Command/Option/Control, Tab, Space, Backspace, Return, and Mac input-source controls. Special mode adds navigation, function, editing and shortcut controls. Highlighted modifiers remain held until tapped again or cleared. Keys execute against the Mac's active keyboard layout/input method; this is not an iPad-native IME or local candidate bar. Common shortcuts retain the existing explicit clipboard-sharing flow.

The keyboard uses the existing bottom inset, with a bounded scrollable height for compact windows. Opening it closes the side drawer. No pointer mapping, zoom math or cursor alignment code changed.

Verification: 147 tests passed, including all basic letters/digits, shifted symbol labels and custom/system-keyboard suppression combinations. iOS device-target compilation succeeded. These are automated policy/build checks; a physical iPad keyboard placement, rotation, Chinese-input and hardware-keyboard coexistence check remains necessary. No upload or installed-app replacement was performed.

Logs: `/Volumes/D/build/SidecarBridge-security-audit-20260913/custom-keyboard-tests.log` and `custom-keyboard-ipad-final.log`.
