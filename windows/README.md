# SidecarBridge Windows companion

This folder contains the Windows host for SidecarBridge. It is a native Win32
C++ host with a WebView2 dashboard and a direct, encrypted iPad transport. The
host listens on TCP `45454`, advertises the same `_sb-direct._tcp` service used
by the macOS app, and implements the public SidecarBridge v3 wire protocol:
X25519 key agreement, HKDF-SHA256 direction keys, ChaCha20-Poly1305 records,
16-digit first pairing, saved DPAPI-protected credentials, JPEG desktop
frames, SendInput pointer/keyboard events, committed Unicode text, scroll, and
incoming file transfer. Modifier arrays (Control/Option/Shift/Command), the
iPad 中/英 input-source key, and current-pointer drag events are translated by
the host instead of being treated as plain clicks.

## Project shape

```text
windows/
├── CMakeLists.txt
├── CMakePresets.json
├── src/
│   ├── bridge_session.cpp/.h   # WebView message/state boundary
│   ├── bridge_transport.cpp/.h # encrypted LAN host, capture, and input
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
- OpenSSL 1.1.1 or newer (Crypto component). The native host uses OpenSSL's
  X25519, HKDF, HMAC, and ChaCha20-Poly1305 implementations; copy the matching
  `libcrypto` DLL beside the executable for a portable release.
- The `Microsoft.Web.WebView2` NuGet package, or an extracted WebView2 SDK
  directory containing `build/native/include/WebView2.h` and the architecture-
  specific loader library.

Microsoft's [WebView2 Win32 getting-started guide](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/win32)
describes the SDK and Runtime setup.

## Configure and build (PowerShell)

From the repository root:

```powershell
$env:WEBVIEW2_SDK_DIR = "C:\path\to\Microsoft.Web.WebView2"
$env:OPENSSL_ROOT_DIR = "C:\path\to\OpenSSL"
cmake --preset windows-x64
cmake --build windows\build\x64 --config Release
windows\build\x64\Release\SidecarBridgeWindows.exe
```

If you do not want to use the preset, the equivalent configure command is:

```powershell
cmake -S windows -B windows\build\x64 `
  -G "Visual Studio 17 2022" -A x64 `
  -DWEBVIEW2_SDK_DIR="$env:WEBVIEW2_SDK_DIR" `
  -DOPENSSL_ROOT_DIR="$env:OPENSSL_ROOT_DIR"
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

## Host behavior

The native process starts the listener when the WebView sends `ready`, and the
listener remains active while the window is minimized. The dashboard shows the
one-time pairing code; the iPad app is the client and must select this Windows
host before it connects. After the first successful code proof, the host saves
the issued credential with Windows DPAPI and subsequent connections do not ask
for the code again. Files received from the iPad are written to
`%USERPROFILE%\\Downloads\\SidecarBridge Transfers`.

The capture path intentionally uses a bounded GDI/WIC JPEG frame so it has no
unbounded queue under RAM pressure. Clipboard text is exchanged through the
authenticated control channel and is capped at 48 KiB. Incoming files use a
bounded 512 MiB transfer, sanitized leaf names, chunk acknowledgements, and a
Downloads/SidecarBridge Transfers destination. It is a local display stream,
not a Windows virtual monitor; adding a true virtual display would require a
separately signed [Indirect Display Driver](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview).

The Windows version cannot use Apple's private Sidecar transport. A virtual
display driver and a local authenticated stream are separate Windows features
and should be implemented and reviewed independently.

## Security boundary

The iPad and Windows host authenticate the device identity and pairing proof
before any input or frame is accepted. Every record has a direction-specific
key, monotonic counter, and replay window. Do not expose the WebView2 debug
port or map arbitrary filesystem paths into the virtual host. Windows Firewall
must allow the app to accept local TCP connections on port 45454.

## Compatibility note

The Windows host cannot use Apple's private Sidecar transport. It is a public
SidecarBridge LAN host for the iPad app, so both devices must have a reachable
local address. Bonjour filtering is handled by the iPad's fixed-port direct
fallback; Internet relay and Apple's virtual display are out of scope.
