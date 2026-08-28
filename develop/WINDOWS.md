# SidecarBridge Windows companion

The `windows` branch contains the Windows companion prototype. Its native
shell is written in C++ with Win32 and WebView2; the local HTML/CSS/JavaScript
dashboard lives in `windows/web/`.

## Build prerequisites

- Windows 10 or later, x64 for the current bundle.
- Visual Studio 2022 with Desktop development with C++ and a Windows SDK.
- The Microsoft WebView2 SDK for source builds.

Configure and build from the repository root on Windows:

```powershell
$env:WEBVIEW2_SDK_DIR = "C:\path\to\Microsoft.Web.WebView2"
cmake --preset windows-x64
cmake --build windows\build\x64 --config Release
```

For a portable release, keep `SidecarBridgeWindows-x86_64.exe`,
`WebView2Loader.dll`, `web/`, and `WebView2Runtime/` together. The fixed
WebView2 runtime is architecture-specific and avoids requiring a separate
system WebView2 installation.

## Current boundary

This branch is the Windows shell and protocol boundary. It accepts and
validates a 16-digit pairing code (dashes are allowed), but it does not claim
that a remote session is connected until the Windows transport, capture, input,
and file-transfer backends are implemented and tested on Windows.

The Windows implementation cannot use Apple’s private Sidecar transport. Any
future remote-control backend must use explicit consent, authenticated device
identity, replay protection, and safe credential storage.
