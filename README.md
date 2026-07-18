# SidecarBridge

For the full architecture, protocol, permission, distribution, testing, and troubleshooting reference, see [SIDECARBRIDGE_TECHNICAL_GUIDE.md](SIDECARBRIDGE_TECHNICAL_GUIDE.md).

SidecarBridge is a paired macOS + iPadOS app that removes most of the friction from using an iPad as a Mac display.

When either app starts, it uses this order:

1. Wait for SidecarBridge on iPad to report its selected display mode.
2. By default, discover the Mac directly with Bonjour and stream over an encrypted local-network or AWDL connection with Magic Keyboard and trackpad input. This stays inside SidecarBridge on iPad and does not open Apple's Continuity/Sidecar screen.
3. If direct LAN is unavailable, retain Multipeer Connectivity as the nearby/peer-to-peer fallback.
4. Never launch native Sidecar automatically. The separate system Sidecar session starts only after the user explicitly clicks **Open System Sidecar**.
5. Keep a button to open Apple's Displays settings when manual intervention is needed.

The in-app stream first uses Network.framework Bonjour discovery across the local network and Apple peer-to-peer link technologies. Each direct session performs ephemeral Curve25519 key agreement and encrypts screen/input packets with ChaChaPoly. Multipeer Connectivity remains available as a delayed fallback. It is intentionally local/nearby only; this project does not publish the Mac screen to the public Internet.

## Build and install

Requirements: Xcode 16 or newer, XcodeGen, macOS 14+, and iPadOS 17+.

```sh
./scripts/build.sh
/Volumes/D/Xcode.app/Contents/MacOS/Xcode \
  /Volumes/D/github/sidecar/SidecarBridge.xcodeproj
```

In Xcode:

1. Select the `SidecarBridgeMac` target, choose your Apple development team, then run it on **My Mac**.
2. Select `SidecarBridgePad`, choose the same or another valid development team, connect the iPad, and run it on the iPad.
3. Accept **Local Network** on both devices.
4. The first time the iPad finds the Mac, approve the one-time pairing alert on the Mac.
5. If the fallback is needed, grant **Screen Recording** to SidecarBridge on the Mac, quit it, and reopen it.

For automatic startup, use the **Automatic startup** card in the Mac app. It distinguishes enabled, disabled, and macOS-approval-required states. If the app was moved or rebuilt after startup was enabled, click **Repair** once so the Login Item points to `/Volumes/D/Applications/SidecarBridge.app` instead of an old Xcode build.

For reliable native Sidecar, both devices should use the same Apple Account with two-factor authentication. Wireless Sidecar also needs Wi-Fi, Bluetooth, and Handoff; USB Sidecar needs the iPad to trust the Mac.

If the app reports `NoAuth`, macOS or iPadOS has denied Local Network access. Use the app's **Allow Local Network** button and enable SidecarBridge in the system privacy page. Bonjour discovery cannot operate until this Apple-controlled permission is granted.

## What is and is not possible

Apple's native Sidecar stream cannot be embedded inside a third-party iPad app. iPadOS presents it through Apple's separate Sidecar system app and suspends the native session when the user switches to another iPad app. SidecarBridge therefore keeps **In-App Display** and **System Sidecar** as honest, separate modes.

Apple also does not publish a third-party API that starts a Sidecar session. The explicit **Open System Sidecar** action dynamically calls `SidecarCore`, a private macOS framework. It is suitable for a personal sideloaded build, but it is not App Store-safe and can break after a macOS update.

The code automatically falls back instead of trying to bypass iPadOS security:

- `SidecarConnector` uses the private native connection path.
- `CableDetector` checks the USB registry and prefers wired transport.
- `ScreenStreamer` uses Apple's public ScreenCaptureKit API.
- `MacLANService` and `PadLANService` use Bonjour plus Network.framework so the paired apps can connect on the same Wi-Fi even if Apple's Sidecar device list is empty.
- The two apps use an encrypted Multipeer Connectivity session and remember the approved iPad name for automatic reconnection.

The fallback is a hardware-encoded H.264 HiDPI stream sized from the iPad's native display width (clamped to 1440–2880 pixels, up to 30 fps) with optional remote keyboard, trackpad, touch, and Apple Pencil input. JPEG packets remain supported for compatibility. It mirrors the main display rather than creating a true extra macOS display. Native Sidecar remains the preferred path for a true virtual Retina display, native Apple Pencil behavior, audio, and extended-desktop support.

Closing the Mac window leaves SidecarBridge available as a background app so an iPad can reconnect. On iPadOS, the app uses the system's short background-task grace period and reconnects automatically when brought to the foreground; iPadOS does not permit an ordinary screen-viewer app to stream indefinitely while fully backgrounded.

### Magic Keyboard and trackpad

Apple supports typing with a Smart Keyboard or Magic Keyboard connected to the iPad during native Sidecar, but specifies a mouse or trackpad connected to the **Mac** (or Apple Pencil on iPad) for pointing. SidecarBridge therefore defaults to **Use app stream for Magic Keyboard + trackpad** on the iPad. This selects the fallback stream and forwards:

- trackpad hover/pointer movement, distinct left click, double-click, and right click, click-and-drag, continuous or wheel scrolling, and two-finger touch scrolling;
- direct touch or Apple Pencil pointer movement and taps;
- text, arrows, Return, Tab, Escape, Delete, and common Command shortcuts.

Remote input requires enabling SidecarBridge in **System Settings → Privacy & Security → Accessibility** on the Mac. macOS does not allow an app to add or authorize itself. In the Mac app, click **Open Accessibility**, click the `+` button in System Settings, then select SidecarBridge. If the app is hard to locate, click **Show App** first and drag the revealed app into the Accessibility list. Input events are accepted only through the already encrypted, paired app session.

The iPad viewer recognizes one primary tap as left click, two primary taps as a true macOS double-click, and a secondary trackpad click as right click. The right-edge viewer drawer also exposes clearly labeled **Left**, **Double**, and **Right** buttons that act at the current Mac pointer position.

## Research

- [Apple: Use your iPad as a second display for your Mac](https://support.apple.com/guide/mac-help/use-your-ipad-as-a-second-display-mchlf3c6f7ae/mac)
- [Apple: Sidecar system requirements](https://support.apple.com/102597)
- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Apple: Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)
- [Apple: Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) — demonstrated the private SidecarCore selectors and wired transport value; MIT-licensed, but explicitly subject to breakage after macOS updates.

## Security notes

- Multipeer Connectivity encryption is required.
- The Mac asks before pairing with a new iPad peer name and automatically accepts that name later.
- Peer names are convenient identifiers, not strong cryptographic device identities. Use this on a trusted local network.
- Public-Internet streaming would need authenticated identities, certificate pinning, a relay/VPN path, and stronger session authorization; it is deliberately outside this MVP.
