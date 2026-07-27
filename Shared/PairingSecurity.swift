import CryptoKit
import Foundation
import Security

enum PairingMessageKind: String, Codable, Equatable {
    case response
    case accepted
    case rejected
}

struct PairingMessage: Codable, Equatable {
    let kind: PairingMessageKind
    var proof: Data? = nil
    var credential: Data? = nil
    var detail: String? = nil
}

enum PairingProof {
    static func make(
        secret: Data,
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Data {
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(
            for: transcript(
                identity: identity,
                macID: macID,
                nonce: nonce,
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey
            ),
            using: key
        ))
    }

    static func verify(
        _ proof: Data,
        secret: Data,
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript(
                identity: identity,
                macID: macID,
                nonce: nonce,
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey
            ),
            using: SymmetricKey(data: secret)
        )
    }

    private static func transcript(
        identity: BridgePeerIdentity,
        macID: String,
        nonce: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Data {
        var data = Data("SidecarBridge-Pairing-v1\u{0}".utf8)
        for value in [identity.stableKey, identity.deviceName, identity.deviceKind, macID] {
            data.append(Data(value.utf8))
            data.append(0)
        }
        data.append(nonce)
        data.append(clientPublicKey)
        data.append(serverPublicKey)
        return data
    }
}

enum SecureCredentialStore {
    private static let service = "io.sidecarbridge.trusted-devices"

    static func data(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
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
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func removeAll(accountPrefix: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let records = result as? [[CFString: Any]] else { return }
        for record in records {
            guard let account = record[kSecAttrAccount] as? String,
                  account.hasPrefix(accountPrefix) else { continue }
            remove(account: account)
        }
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        }
        return Data(bytes)
    }
}
