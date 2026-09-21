import Foundation

/// A short-lived, local-only route hint. Scanning is not consent to connect
/// and is never a substitute for the existing mutual pairing proof.
struct PairingInvitation: Equatable {
    let macID: String
    let name: String
    let code: String
    let hosts: [String]
    let expiresAt: Date

    static func displayName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 128 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Mac" : result
    }

    enum ValidationError: LocalizedError {
        case invalid, expired
        var errorDescription: String? {
            switch self {
            case .invalid: return "This is not a valid SidecarBridge pairing QR code. Use the code shown in the Mac app."
            case .expired: return "This pairing QR code has expired. Scan the current code in the Mac app."
            }
        }
    }

    var encoded: String {
        var url = URLComponents()
        url.scheme = "sidecarbridge"
        url.host = "pair"
        url.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: macID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return url.string ?? ""
    }

    static func decode(_ value: String, now: Date = Date()) throws -> Self {
        guard value.utf8.count <= 2048,
              let url = URLComponents(string: value),
              url.scheme == "sidecarbridge", url.host == "pair",
              url.path.isEmpty, url.port == nil, url.user == nil,
              url.password == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 6,
              Set(items.map(\.name)) == Set(["v", "id", "name", "code", "hosts", "expires"])
        else { throw ValidationError.invalid }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard fields["v"] == "1",
              let id = fields["id"], !id.isEmpty, id.utf8.count <= 128,
              let name = fields["name"], !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let code = fields["code"], code.count == PairingCode.digitCount,
              code == PairingCode.normalize(code),
              let timestamp = fields["expires"].flatMap(TimeInterval.init), timestamp.isFinite
        else { throw ValidationError.invalid }
        let hosts = (fields["hosts"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let addresses = hosts == [""] ? [] : hosts
        guard addresses.count <= 8,
              addresses.allSatisfy(BridgeNetworkMetadata.isPrivateIPv4Address)
        else { throw ValidationError.invalid }
        let expiry = Date(timeIntervalSince1970: timestamp)
        guard expiry > now else { throw ValidationError.expired }
        guard expiry.timeIntervalSince(now) <= PairingCode.lifetime + 60 else { throw ValidationError.invalid }
        return Self(macID: id, name: name, code: code, hosts: addresses, expiresAt: expiry)
    }
}

/// Explicit repair codes must win over a stale saved credential. Rejection
/// alone is not proof of a Mac's identity and must never delete Keychain data.
enum PairingSecretSelection {
    static func select(code: String?, savedCredential: Data?) -> (secret: Data, usedSaved: Bool)? {
        if let code, code.count == PairingCode.digitCount, code == PairingCode.normalize(code) {
            return (Data(code.utf8), false)
        }
        if let savedCredential, savedCredential.count == 32 {
            return (savedCredential, true)
        }
        return nil
    }
}

enum ConnectionRoutePolicy {
    /// A failed standby LAN probe must not reset an active nearby stream or
    /// publish another "connected" event that rebuilds its video decoder.
    static func shouldApplyLANEvent(wasLANConnected: Bool, connected: Bool, nearbyConnected: Bool) -> Bool {
        wasLANConnected || connected || !nearbyConnected
    }
}

/// Guards callbacks queued to the UI across an explicit Cancel/new attempt.
final class ConnectionAttemptToken {
    private let lock = NSLock()
    private var current = UUID()

    @discardableResult
    func begin() -> UUID {
        lock.lock(); defer { lock.unlock() }
        current = UUID()
        return current
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == token
    }
}

struct SavedMacRoute: Codable, Equatable {
    let macID: String
    let name: String
    let hosts: [String]
}

/// Non-secret routing metadata, written only AFTER server-proof validation
/// and credential persistence. Authentication secrets remain in Keychain.
enum SavedMacRouteStore {
    private static let key = "authenticatedMacRoutesV1"
    private static let lock = NSLock()

    static func route(named name: String, defaults: UserDefaults = .standard) -> SavedMacRoute? {
        lock.lock(); defer { lock.unlock() }
        return load(defaults).first { $0.name == name }
    }

    static func remember(macID: String, name: String, hosts: [String], defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var routes = load(defaults)
        let previous = routes.first { $0.macID == macID }
        let addresses = Array(Set((hosts + (previous?.hosts ?? [])).filter(BridgeNetworkMetadata.isPrivateIPv4Address))).sorted()
        routes.removeAll { $0.macID == macID || $0.name == name }
        routes.insert(SavedMacRoute(macID: macID, name: name, hosts: Array(addresses.prefix(8))), at: 0)
        if let data = try? JSONEncoder().encode(Array(routes.prefix(32))) {
            defaults.set(data, forKey: key)
        }
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private static func load(_ defaults: UserDefaults) -> [SavedMacRoute] {
        guard let data = defaults.data(forKey: key), data.count <= 65536,
              let routes = try? JSONDecoder().decode([SavedMacRoute].self, from: data) else { return [] }
        return routes
    }
}
