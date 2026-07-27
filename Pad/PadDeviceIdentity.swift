import Foundation
import UIKit

enum PadDeviceIdentity {
    private static let identifierKey = "authorizedDeviceIdentifier"

    static let current: BridgePeerIdentity = {
        let defaults = UserDefaults.standard
        let identifier: String
        if let saved = defaults.string(forKey: identifierKey), !saved.isEmpty {
            identifier = saved
        } else {
            identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            defaults.set(identifier, forKey: identifierKey)
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
