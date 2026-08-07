import AppKit
import Foundation

/// App Store builds may only use Apple's documented public APIs. Native
/// Sidecar does not expose an API for third-party apps to enumerate devices or
/// start a session, so this bridge opens the public Displays settings UI.
final class SidecarConnector {
    enum Transport: String {
        case wired
        case wireless
    }

    enum ConnectorError: LocalizedError {
        case useSystemSettings

        var errorDescription: String? {
            "Choose your iPad in System Settings → Displays. Apple does not provide a public API that lets SidecarBridge start native Sidecar."
        }
    }

    func reachableDeviceNames() -> [String] {
        []
    }

    func connect(
        preferredName: String?,
        transport: Transport,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"
        )
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
        DispatchQueue.main.async {
            completion(.failure(ConnectorError.useSystemSettings))
        }
    }
}
