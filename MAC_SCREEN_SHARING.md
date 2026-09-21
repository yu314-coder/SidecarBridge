# Mac Screen Sharing: no Mac companion installation

This optional iOS/iPadOS mode connects to macOS's built-in Screen Sharing
server using standard VNC/RFB. Only the iPhone/iPad needs SidecarBridge installed.
The Mac still requires a one-time setup in System Settings.

This is **not Apple's native Sidecar** and does not create an extended display.
It views and controls the existing Mac desktop. It uses public Network.framework,
CoreGraphics, UIKit, and Keychain APIs, without SidecarCore, helper installation,
Apple Events, or a private USB tunnel.

## First connection

1. On the Mac, open **System Settings → General → Sharing → Screen Sharing**.
   Enable Screen Sharing; if Remote Management is enabled, macOS may require
   turning that off first.
2. In Screen Sharing's options, enable **VNC viewers may control screen with
   password** and set a separate VNC password. This client accepts 1–8 ASCII
   characters, matching legacy VNC authentication's eight-byte limit. Do not use
   your Apple Account password or a valuable password reused elsewhere.
3. Find the Mac's local IP address in Network settings, or use its `.local`
   hostname. Both devices need a reachable private-network path; Ethernet on the
   Mac and Wi-Fi on the iPad are supported when the router permits communication.
4. On SidecarBridge's disconnected dashboard, tap **Mac Screen Sharing**. Enter
   the Mac address, port (normally **5900**), and VNC password.
5. Read the unencrypted-transport warning, confirm that you trust the network,
   and tap **Connect**. Connection is always user-initiated.

The SidecarBridge 16-digit pairing code is not used in this mode. After a
successful first frame, the password can be saved in the iPad's Keychain under
the host and port. Leave the password field blank to reuse it. **Forget saved
password** removes that endpoint's credential. Changing address/hostname creates
a separate credential entry. There is no claim that reinstall, signing changes,
or device reset will always preserve credentials.

## Controls and behavior

- Touch/trackpad/mouse input uses the existing input surface, with left/right
  clicks, double-clicks, held drag, and scrolling translated to VNC messages.
- Keyboard input includes Command, Control, Option, Shift, arrows, navigation,
  function keys, and Unicode keysyms. macOS shortcut assignments and the VNC
  server's keyboard support determine the resulting action.
- The keyboard button exposes the software keyboard with a modifier/navigation
  row. Pinch zoom is local to the viewer (1×–4×); three-finger drag pans it.
- Command-V executes paste on the Mac, using the Mac clipboard. This mode never
  automatically reads the iPad clipboard or transfers clipboard contents.
- Backgrounding deliberately ends this connection and clears the old framebuffer.
  Returning requires **Connect**, authenticates again with the saved password,
  and requests a new full frame. It does not promise indefinite iOS background
  execution or reuse a stale screenshot as a live connection.

## Limits and security

Legacy VNC uses DES challenge-response authentication and does **not** encrypt the
screen or input stream. It does not authenticate the server's identity either.
Use only on a trusted private network; do not port-forward TCP 5900 to the
Internet. SidecarBridge explicitly refuses unauthenticated VNC security type
`None`. For SidecarBridge's encrypted transport and optimized streaming, continue
using the existing Mac companion route instead.

A USB cable by itself does not make macOS Screen Sharing reachable. No automatic
USB tunnel, Internet relay, Bluetooth transport, or guaranteed AWDL discovery is
implemented here. A separately available IP connection over a wired interface
can work, but is not created by this app.

The implementation negotiates RFB 3.3/3.7/3.8 (including a Mac 3.889 banner), VNC
password authentication, RGBX pixels, Raw, CopyRect, and DesktopSize. It requests
one framebuffer update at a time, reads pixel data in bounded chunks, checks
rectangle/message dimensions, and caps framebuffers at 16 megapixels. It does
not promise 60/120 FPS, audio, file transfer, or support for Apple-only account
authentication. Legacy raw VNC can use substantially more bandwidth than the
companion's compressed stream.

## Troubleshooting

- Address not reachable: check the address, Mac sleep state, Screen Sharing,
  firewall, and router client isolation. Same Internet access is not proof of
  local reachability. VPN configuration can also affect routes.
- “Enable VNC viewers…”: the server does not offer VNC password authentication.
- Password rejected: use the separate VNC password in Screen Sharing settings,
  not the Mac login password or SidecarBridge code.
- Connection times out: the client allows 20 seconds for connection,
  authentication, and the first full frame; it then cancels rather than showing
  an indefinitely loading or stale desktop.

## Verification

`Tests/RFBProtocolTests.swift` covers an independent OpenSSL DES vector, invalid
passwords, malformed framebuffer bounds, overlapping CopyRect, key and mouse
messages, authentication rejection, and loopback network integration. The mock
server verifies protocol negotiation, fragmented reads, RGBX frames, dynamic
resize, outgoing keyboard messages, and clean disconnect errors.

These tests do not substitute for physical iPad/Mac testing. Before distribution,
verify a real Mac's VNC authentication, screen colors, clicks/drags, Magic Keyboard
shortcuts and text entry, display resize, background/reconnect, and Keychain reuse.
No real-device VNC session has been verified for this addition. The iOS/iPadOS
**1.3 (13)** upload is now **VALID** in App Store Connect and **IN_BETA_TESTING**
for internal testers, with setup and test notes saved. It was not submitted to
App Review or external beta review. See the [release record](releases/1.3-ios13.md).

References: [Apple Screen Sharing setup](https://support.apple.com/guide/mac-help/mh11848/mac),
[RFB protocol RFC 6143](https://www.rfc-editor.org/rfc/rfc6143).
