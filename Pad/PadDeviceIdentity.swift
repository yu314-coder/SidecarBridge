import Foundation
import UIKit

enum PadDeviceIdentity {
    private static let identifierKey = "authorizedDeviceIdentifier"
    private static let keychainAccount = "pad.identity"

    static let current: BridgePeerIdentity = {
        let defaults = UserDefaults.standard
        let identifier: String
        if let saved = SecureCredentialStore.data(account: keychainAccount)
            .flatMap({ String(data: $0, encoding: .utf8) }),
           !saved.isEmpty {
            identifier = saved
            // Keep the old defaults value in sync for diagnostics and for
            // older builds that may be launched during an upgrade.
            defaults.set(saved, forKey: identifierKey)
        } else if let saved = defaults.string(forKey: identifierKey), !saved.isEmpty {
            identifier = saved
            // Migrate the pre-Keychain identity so an App Store update (and
            // a reinstall that preserves this app's keychain access group)
            // keeps the same peer identity and trusted Mac account.
            SecureCredentialStore.set(Data(saved.utf8), account: keychainAccount)
        } else {
            identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            defaults.set(identifier, forKey: identifierKey)
            SecureCredentialStore.set(Data(identifier.utf8), account: keychainAccount)
        }

        let kind: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: kind = "iPhone"
        case .pad: kind = "iPad"
        default: kind = "iOS device"
        }

        return BridgePeerIdentity(
            deviceID: identifier,
            deviceName: UIDevice.current.name,
            deviceKind: kind
        )
    }()
}
