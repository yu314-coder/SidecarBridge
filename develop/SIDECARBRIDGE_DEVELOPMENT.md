# SidecarBridge development guide

This repository contains the Apple SidecarBridge application. The `main`
branch is the source of truth for the iPadOS and macOS targets and their
shared Swift networking, streaming, input, and file-transfer code.

## Branch layout

- `main` — iPadOS/macOS app, shared Swift code, tests, project configuration,
  and release documentation.
- `windows` — the Windows companion prototype in `windows/`. It is a native
  Win32 C++ shell with a WebView2 front end and is intentionally isolated from
  the Apple targets.

## Apple development

Open `SidecarBridge.xcodeproj` in Xcode, select the appropriate iPadOS or
macOS scheme, and run the unit tests before archiving. Keep archives and build
caches outside the repository. The transport uses authenticated local
connections; public-Internet relay behavior is not implied by local discovery.

## Windows development

Switch to the `windows` branch and read [`WINDOWS.md`](WINDOWS.md) for the
source layout, WebView2 SDK setup, supported architectures, and the current
transport boundary. The Windows shell does not use Apple's private Sidecar
transport.

## Release hygiene

Do not commit signing certificates, provisioning profiles, App Store Connect
keys, private logs, or generated archives. Review `git status` and the staged
file list before every push. A successful cross-build is not proof of runtime
behavior; test the artifact on its target operating system.
