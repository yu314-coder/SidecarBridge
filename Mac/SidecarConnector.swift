import AppKit
import Foundation

/// Opens Apple's user-controlled setup. It does not enumerate native Sidecar
/// devices, start a native session, or use the private SidecarCore framework.
@MainActor
final class SidecarConnector {
    private let openURL: (URL) -> Bool
    private let settingsApplicationURL: () -> URL?

    init(
        openURL: ((URL) -> Bool)? = nil,
        settingsApplicationURL: (() -> URL?)? = nil
    ) {
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        self.settingsApplicationURL = settingsApplicationURL ?? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
        }
    }

    /// True means Launch Services accepted an open request, NOT that Displays
    /// loaded or a native session started. The pane URL is best-effort; fall
    /// back to the Settings app if its handler is unavailable.
    func openSettings() -> Bool {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"),
           openURL(pane) { return true }
        guard let application = settingsApplicationURL() else { return false }
        return openURL(application)
    }
}
