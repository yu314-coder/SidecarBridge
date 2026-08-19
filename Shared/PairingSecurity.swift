import CryptoKit
import Foundation
import Security

enum PairingMessageKind: String, Codable, Equatable {
    case challenge
    case response
    case accepted
    case rejected
}

struct PairingMessage: Codable, Equatable {
    let kind: PairingMessageKind
    var protocolVersion: Int? = nil
    var identity: BridgePeerIdentity? = nil
    var macID: String? = nil
    var nonce: Data? = nil
    var ephemeralPublicKey: Data? = nil
    var requiresPairingCode: Bool? = nil
    var proof: Data? = nil
    var credential: Data? = nil
    var detail: String? = nil
}

extension PairingMessage {
    var isStructurallyValid: Bool {
        guard protocolVersion == LANWire.securityProtocolVersion,
              (detail?.utf8.count ?? 0) <= 512 else { return false }
        switch kind {
        case .challenge:
            return identity == nil &&
                (macID?.utf8.count ?? 0) > 0 &&
                (macID?.utf8.count ?? 0) <= 128 &&
                nonce?.count == 32 &&
                ephemeralPublicKey?.count == 32 &&
                proof == nil &&
                credential == nil
        case .response:
            return identity?.isValidForAuthentication == true &&
                proof?.count == 32 &&
                macID == nil &&
                nonce == nil &&
                ephemeralPublicKey == nil &&
                credential == nil
        case .accepted:
            return identity == nil &&
                proof?.count == 32 &&
                macID == nil &&
                nonce == nil &&
                ephemeralPublicKey == nil &&
                (credential == nil || credential?.count == 32)
        case .rejected:
            return identity == nil &&
                proof == nil &&
                ephemeralPublicKey == nil &&
                credential == nil
        }
    }
}

struct MultipeerInvitationContext: Codable, Equatable {
    let protocolVersion: Int
    let identity: BridgePeerIdentity
    let clientPublicKey: Data
}

enum PairingProofRole: String {
    case client
    case server
}

enum PairingCode {
    /// A first-time device enters this short-lived numeric code. The Mac
    /// issues it locally; after verification, the random Keychain credential
    /// is used instead so trusted devices do not have to re-enter it.
    static let digitCount = 16
    // Keep the existing internal name for protocol call sites and older
    // tests. It describes the length, not an allowance for alphabetic input.
    static let characterCount = digitCount
    static let lifetime: TimeInterval = 5 * 60

    static func generate() -> String {
        let bytes = SecureCredentialStore.randomBytes(count: characterCount)
        // The code is intentionally numeric so it can be entered quickly on
        // an iPad hardware/software keyboard. A five-minute lifetime and the
        // existing per-device/global attempt limits protect the one-time
        // secret while the trusted credential remains much stronger.
        return String(bytes.map { Character(String(Int($0) % 10)) })
    }

    static func normalize(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            (0x30...0x39).contains(scalar.value)
        })
    }

    static func formatted(_ value: String) -> String {
        let normalized = normalize(value)
        return stride(from: 0, to: normalized.count, by: 4).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: min(4, normalized.count - offset))
            return String(normalized[start..<end])
        }.joined(separator: "-")
    }

    /// Formats live text-field input while the user types or pastes. This
    /// keeps the four-digit groups visible without ever sending separators as
    /// part of the proof secret.
    static func formattedInput(_ value: String) -> String {
        let normalized = String(normalize(value).prefix(digitCount))
        return formatted(normalized)
    }
}

enum PairingProof {
    static func make(
        secret: Data,
        role: PairingProofRole,
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        channelBinding: Data
    ) -> Data {
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(
            for: transcript(
                role: role,
                identity: identity,
                macID: macID,
                nonce: nonce,
                channelBinding: channelBinding
            ),
            using: key
        ))
    }

    static func verify(
        _ proof: Data,
        secret: Data,
        role: PairingProofRole,
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        channelBinding: Data
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript(
                role: role,
                identity: identity,
                macID: macID,
                nonce: nonce,
                channelBinding: channelBinding
            ),
            using: SymmetricKey(data: secret)
        )
    }

    static func lanChannelBinding(clientPublicKey: Data, serverPublicKey: Data) -> Data {
        var data = Data("SidecarBridge-LAN-binding-v2\u{0}".utf8)
        appendLengthPrefixed(clientPublicKey, to: &data)
        appendLengthPrefixed(serverPublicKey, to: &data)
        return data
    }

    static func multipeerChannelBinding(clientPublicKey: Data, serverPublicKey: Data) -> Data {
        var data = Data("SidecarBridge-Multipeer-binding-v3\u{0}".utf8)
        appendLengthPrefixed(clientPublicKey, to: &data)
        appendLengthPrefixed(serverPublicKey, to: &data)
        return data
    }

    private static func transcript(
        role: PairingProofRole,
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        channelBinding: Data
    ) -> Data {
        var data = Data("SidecarBridge-Pairing-v2\u{0}".utf8)
        for value in [role.rawValue, identity.stableKey, identity.deviceName, identity.deviceKind, macID] {
            appendLengthPrefixed(Data(value.utf8), to: &data)
        }
        appendLengthPrefixed(nonce, to: &data)
        appendLengthPrefixed(channelBinding, to: &data)
        return data
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

enum SecureCredentialStore {
    private static let service = "io.sidecarbridge.trusted-devices"

    static func data(account: String) -> Data? {
        var query = baseQuery(account: account, dataProtection: true)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let protectedStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if protectedStatus == errSecSuccess {
            return item as? Data
        }

        // Builds before the data-protection migration stored these entries in
        // the login Keychain. On macOS, an update/relaunch can also make the
        // protected query temporarily unavailable while the login session is
        // being restored. Read the legacy item as a persistence fallback so a
        // trusted device does not get downgraded to first-time pairing.
        var legacyQuery = baseQuery(account: account, dataProtection: false)
        legacyQuery[kSecReturnData] = true
        legacyQuery[kSecMatchLimit] = kSecMatchLimitOne
        var legacyItem: CFTypeRef?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem) == errSecSuccess,
              let legacyData = legacyItem as? Data else { return nil }
        // Best-effort migration; retain the legacy item until the protected
        // copy is confirmed on a later read so a transient Keychain error
        // cannot discard the only saved credential.
        _ = setProtected(legacyData, account: account)
        return legacyData
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let protectedSaved = setProtected(data, account: account)
        let legacySaved = setLegacy(data, account: account)
        return protectedSaved || legacySaved
    }

    @discardableResult
    private static func setProtected(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account, dataProtection: true)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func setLegacy(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account, dataProtection: false)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func remove(account: String) {
        SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    static func removeAll(accountPrefix: String) {
        removeAll(accountPrefix: accountPrefix, dataProtection: true)
        removeAll(accountPrefix: accountPrefix, dataProtection: false)
    }

    private static func removeAll(accountPrefix: String, dataProtection: Bool) {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let records = result as? [[CFString: Any]] else { return }
        for record in records {
            guard let account = record[kSecAttrAccount] as? String,
                  account.hasPrefix(accountPrefix) else { continue }
            SecItemDelete(
                baseQuery(account: account, dataProtection: dataProtection) as CFDictionary
            )
        }
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        }
        return Data(bytes)
    }
}
