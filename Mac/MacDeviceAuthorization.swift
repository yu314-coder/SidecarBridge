import Foundation
import LocalAuthentication

struct MacAuthorizedDevice: Codable, Equatable {
    let deviceID: String
    var deviceName: String
    var deviceKind: String
    let authorizedAt: Date
    var lastSeenAt: Date
}

struct PairingVerification {
    let accepted: Bool
    let issuedCredential: Data?
    let detail: String?
}

@MainActor
final class MacPairingSecurity {
    static let shared = MacPairingSecurity()

    var onPairingCodeChanged: ((String) -> Void)?

    private(set) var pairingCode: String
    let macID: String
    private var failedAttemptTimes: [Date] = []

    private init() {
        if let saved = SecureCredentialStore.data(account: "mac.identity"),
           let value = String(data: saved, encoding: .utf8),
           !value.isEmpty {
            macID = value
        } else {
            let value = UUID().uuidString
            macID = value
            SecureCredentialStore.set(Data(value.utf8), account: "mac.identity")
        }
        pairingCode = Self.makePairingCode()
    }

    func requiresPairingCode(for identity: BridgePeerIdentity) -> Bool {
        credential(for: identity) == nil
    }

    func verify(
        identity: BridgePeerIdentity,
        nonce: Data,
        proof: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> PairingVerification {
        let now = Date()
        failedAttemptTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard failedAttemptTimes.count < 5 else {
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                detail: "Too many incorrect codes. Wait one minute and try again."
            )
        }

        if let existing = credential(for: identity) {
            let accepted = PairingProof.verify(
                proof,
                secret: existing,
                identity: identity,
                macID: macID,
                nonce: nonce,
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey
            )
            if accepted {
                MacAuthorizedDeviceStore.shared.authorize(identity)
                return PairingVerification(accepted: true, issuedCredential: nil, detail: nil)
            }
            failedAttemptTimes.append(now)
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                detail: "The saved device credential was not accepted. Forget this Mac on the mobile device and pair again."
            )
        }

        let accepted = PairingProof.verify(
            proof,
            secret: Data(pairingCode.utf8),
            identity: identity,
            macID: macID,
            nonce: nonce,
            clientPublicKey: clientPublicKey,
            serverPublicKey: serverPublicKey
        )
        guard accepted else {
            failedAttemptTimes.append(now)
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                detail: "Incorrect one-time code."
            )
        }

        let credential = SecureCredentialStore.randomBytes(count: 32)
        guard SecureCredentialStore.set(credential, account: credentialAccount(for: identity)) else {
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                detail: "The trusted-device credential could not be saved in Keychain."
            )
        }
        MacAuthorizedDeviceStore.shared.authorize(identity)
        rotatePairingCode()
        return PairingVerification(accepted: true, issuedCredential: credential, detail: nil)
    }

    func forgetAllDevices() {
        SecureCredentialStore.removeAll(accountPrefix: "mac.peer.")
        failedAttemptTimes.removeAll()
        rotatePairingCode()
    }

    func revokeCredential(for identity: BridgePeerIdentity) {
        SecureCredentialStore.remove(account: credentialAccount(for: identity))
    }

    private func credential(for identity: BridgePeerIdentity) -> Data? {
        SecureCredentialStore.data(account: credentialAccount(for: identity))
    }

    private func credentialAccount(for identity: BridgePeerIdentity) -> String {
        "mac.peer.\(identity.stableKey)"
    }

    private func rotatePairingCode() {
        pairingCode = Self.makePairingCode()
        onPairingCodeChanged?(pairingCode)
    }

    private static func makePairingCode() -> String {
        let bytes = SecureCredentialStore.randomBytes(count: 4)
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100_000_000
        return String(format: "%08u", value)
    }
}

@MainActor
final class MacAuthorizedDeviceStore {
    static let shared = MacAuthorizedDeviceStore()

    private let recordsKey = "authorizedDeviceRecords"
    private let legacyNameKey = "pairedPeerName"
    private(set) var devices: [MacAuthorizedDevice]

    private init() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([MacAuthorizedDevice].self, from: data) {
            devices = decoded
        } else {
            devices = []
        }
    }

    func isAuthorized(_ identity: BridgePeerIdentity) -> Bool {
        if let index = devices.firstIndex(where: { $0.deviceID == identity.stableKey }) {
            devices[index].deviceName = identity.deviceName
            devices[index].deviceKind = identity.deviceKind
            devices[index].lastSeenAt = Date()
            save()
            return true
        }
        if UserDefaults.standard.string(forKey: legacyNameKey) == identity.deviceName {
            authorize(identity)
            UserDefaults.standard.removeObject(forKey: legacyNameKey)
            return true
        }
        return false
    }

    func authorize(_ identity: BridgePeerIdentity) {
        let now = Date()
        if let index = devices.firstIndex(where: { $0.deviceID == identity.stableKey }) {
            devices[index].deviceName = identity.deviceName
            devices[index].deviceKind = identity.deviceKind
            devices[index].lastSeenAt = now
        } else {
            devices.append(MacAuthorizedDevice(
                deviceID: identity.stableKey,
                deviceName: identity.deviceName,
                deviceKind: identity.deviceKind,
                authorizedAt: now,
                lastSeenAt: now
            ))
        }
        save()
    }

    func forgetAll() {
        devices.removeAll()
        UserDefaults.standard.removeObject(forKey: recordsKey)
        UserDefaults.standard.removeObject(forKey: legacyNameKey)
    }

    var displaySummary: String? {
        guard !devices.isEmpty else {
            return UserDefaults.standard.string(forKey: legacyNameKey)
        }
        return devices
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .map { "\($0.deviceName) (\($0.deviceKind))" }
            .joined(separator: ", ")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }
}

@MainActor
final class MacDeviceAuthorizer {
    static let shared = MacDeviceAuthorizer()

    private struct PendingRequest {
        var identity: BridgePeerIdentity
        var completions: [(Bool) -> Void]
    }

    private var pending: [String: PendingRequest] = [:]
    private var order: [String] = []
    private var activeKey: String?

    func authorize(_ identity: BridgePeerIdentity, completion: @escaping (Bool) -> Void) {
        if MacAuthorizedDeviceStore.shared.isAuthorized(identity) {
            completion(true)
            return
        }

        let key = identity.stableKey
        if pending[key] != nil {
            pending[key]?.completions.append(completion)
            return
        }
        pending[key] = PendingRequest(identity: identity, completions: [completion])
        order.append(key)
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard activeKey == nil, let key = order.first, let request = pending[key] else { return }
        activeKey = key

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var authorizationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authorizationError) else {
            finish(key: key, accepted: false)
            return
        }

        let reason = "Authorize \(request.identity.deviceName) (\(request.identity.deviceKind)) for SidecarBridge. This is required only once."
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] accepted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if accepted {
                    MacAuthorizedDeviceStore.shared.authorize(request.identity)
                }
                self.finish(key: key, accepted: accepted)
            }
        }
    }

    private func finish(key: String, accepted: Bool) {
        let callbacks = pending.removeValue(forKey: key)?.completions ?? []
        order.removeAll { $0 == key }
        activeKey = nil
        callbacks.forEach { $0(accepted) }
        startNextIfNeeded()
    }
}
