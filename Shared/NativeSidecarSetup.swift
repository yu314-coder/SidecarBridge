import Foundation

/// A user-selected setup checklist, not a measurement of the active transport.
enum NativeSidecarRoute: String, CaseIterable, Identifiable {
    case nearby
    case usb

    var id: Self { self }
    var title: String { self == .usb ? "USB cable" : "Nearby wireless" }
    var symbol: String { self == .usb ? "cable.connector" : "wifi" }
    var instructions: String {
        self == .usb
            ? "Connect the iPad directly to the Mac with a data-capable USB cable. Unlock it and approve Trust This Computer if asked."
            : "Keep both devices within 10 metres, with Wi-Fi, Bluetooth and Handoff on. Turn off Internet Sharing and Personal Hotspot sharing."
    }
}

struct NativeSidecarSetupRequest: Equatable {
    static let prefix = "sidecar-setup:"
    let id: UUID
    let route: NativeSidecarRoute

    init(id: UUID = UUID(), route: NativeSidecarRoute) {
        self.id = id
        self.route = route
    }

    var wireValue: String { "\(Self.prefix)\(id.uuidString):\(route.rawValue)" }
    var successReply: String { "sidecar-settings-opened:\(id.uuidString)" }
    var failureReply: String { "sidecar-settings-failed:\(id.uuidString)" }

    static func parse(_ value: String) -> Self? {
        guard value.hasPrefix(prefix), value.utf8.count <= 80 else { return nil }
        let fields = value.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let id = UUID(uuidString: String(fields[0])),
              let route = NativeSidecarRoute(rawValue: String(fields[1])) else { return nil }
        return Self(id: id, route: route)
    }
}

/// Settings handoff only. Opening settings or detecting an external display
/// does not prove Apple connected this particular iPad.
struct NativeSidecarSetupProgress: Equatable {
    enum Phase: Equatable { case ready, requesting, chooseOnMac, openManually, noReply }
    private(set) var phase: Phase = .ready
    private(set) var request: NativeSidecarSetupRequest?

    var isRequesting: Bool { phase == .requesting }
    var title: String {
        switch phase {
        case .ready: return "Finish setup on the Mac"
        case .requesting: return "Asking the Mac to open Displays…"
        case .chooseOnMac: return "Choose your iPad on the Mac"
        case .openManually: return "Open Displays on the Mac manually"
        case .noReply: return "The Mac did not confirm the request"
        }
    }
    var detail: String {
        switch phase {
        case .ready: return "SidecarBridge cannot select a native Sidecar device for you."
        case .requesting: return "Your encrypted app connection stays available while you set up Sidecar."
        case .chooseOnMac: return "macOS accepted the settings request. In Displays, use Add Display (+) and select your iPad. This is not yet a Sidecar connection."
        case .openManually: return "Choose Apple menu → System Settings → Displays, or Control Center → Screen Mirroring."
        case .noReply: return "You can still open Displays on the Mac yourself. Update both apps for setup acknowledgements; there is no need to pair again."
        }
    }

    @discardableResult
    mutating func begin(route: NativeSidecarRoute, id: UUID = UUID()) -> NativeSidecarSetupRequest {
        let request = NativeSidecarSetupRequest(id: id, route: route)
        self.request = request
        phase = .requesting
        return request
    }

    @discardableResult
    mutating func receive(_ value: String) -> Bool {
        guard phase == .requesting, let request else { return false }
        // Older App Store builds reply without an identifier. Accept that
        // only while an explicit request is pending on this connection.
        if value == request.successReply || value == "sidecar-settings-opened" {
            phase = .chooseOnMac
        } else if value == request.failureReply || value == "sidecar-settings-failed" {
            phase = .openManually
        } else {
            return false
        }
        self.request = nil
        return true
    }

    mutating func expire(id: UUID) {
        guard phase == .requesting, request?.id == id else { return }
        phase = .noReply
        request = nil
    }

    mutating func reset() { self = Self() }

    static func isSetupStatus(_ value: String) -> Bool {
        value.hasPrefix("sidecar-settings-") || [
            "sidecar-wired", "sidecar-wireless", "sidecar-unavailable",
            "sidecar-failed", "sidecar-connected"
        ].contains(value)
    }
}
