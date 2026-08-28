# SidecarBridge Windows companion

This folder is the Windows starting point for SidecarBridge. It is a native
Win32 C++ host with a WebView2 front end in `web/`. The initial slice is an
honest dashboard and protocol boundary: it accepts and validates a 16-digit
pairing code locally, but it does not claim that a remote session is connected
until a Windows transport backend is attached.

## Project shape

```text
windows/
├── CMakeLists.txt
├── CMakePresets.json
├── src/
│   ├── bridge_session.cpp/.h   # small JSON message/state boundary
│   ├── main.cpp                # Win32 entry point and web-root discovery
│   └── webview.cpp/.h          # WebView2 window host
└── web/
    ├── index.html
    ├── styles.css
    └── app.js
```

## Prerequisites

- Windows 10 or later.
- Visual Studio 2022 with **Desktop development with C++** and a Windows SDK.
- Microsoft Edge WebView2 Runtime (the release bundle includes a fixed
  runtime; source/CMake builds can use the Evergreen Runtime).
- The `Microsoft.Web.WebView2` NuGet package, or an extracted WebView2 SDK
  directory containing `build/native/include/WebView2.h` and the architecture-
  specific loader library.

Microsoft's [WebView2 Win32 getting-started guide](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/win32)
describes the SDK and Runtime setup.

## Configure and build (PowerShell)

From the repository root:

```powershell
$env:WEBVIEW2_SDK_DIR = "C:\path\to\Microsoft.Web.WebView2"
cmake --preset windows-x64
cmake --build windows\build\x64 --config Debug
windows\build\x64\Debug\SidecarBridgeWindows.exe
```

If you do not want to use the preset, the equivalent configure command is:

```powershell
cmake -S windows -B windows\build\x64 `
  -G "Visual Studio 17 2022" -A x64 `
  -DWEBVIEW2_SDK_DIR="$env:WEBVIEW2_SDK_DIR"
```

The post-build step copies `web/` beside the executable. The host maps that
folder to the local virtual host `https://app.sidecarbridge.local/`; no remote
website or public network is needed for the UI.

## Portable release bundle

The distributable folder contains the executable, `WebView2Loader.dll`, the
`web/` assets, and a `WebView2Runtime/` directory. When that directory contains
`msedgewebview2.exe`, the host passes it to WebView2 as a fixed runtime and does
not require WebView2 to be installed system-wide. Keep the directory beside the
executable when copying or archiving the app. The fixed runtime is architecture
specific, so use the x64 bundle on x64 Windows and an ARM64 bundle on ARM64
Windows.

## What is intentionally next

The current shell does not yet implement the Windows equivalents of the Apple
transport, capture, or input layers. The implementation order is:

1. Direct encrypted LAN discovery and pairing using Winsock (with an explicit
   authenticated session and reconnect state machine).
2. Screen capture using [Windows Graphics Capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)
   or the [Desktop Duplication API](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/desktop-duplication-api),
   followed by a hardware-accelerated video encoder.
3. Keyboard, pointer, and gesture input using a consent-based Windows backend
   built around [`SendInput`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
4. File transfer, tray/background lifecycle, and reconnect telemetry.
5. If a true virtual monitor is required, evaluate a signed
   [Indirect Display Driver](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview).

The Windows version cannot use Apple's private Sidecar transport. A virtual
display driver and a local authenticated stream are separate Windows features
and should be implemented and reviewed independently.

## Security boundary

The pairing code is not a substitute for transport authentication. Before a
real connection is enabled, the Windows backend should add device identity,
key agreement, replay protection, explicit consent, and safe credential
storage. Do not expose the WebView2 debug port or map arbitrary filesystem
paths into the virtual host.
