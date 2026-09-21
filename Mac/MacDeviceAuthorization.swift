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
    let responseProof: Data?
    let detail: String?
}

@MainActor
final class MacPairingSecurity {
    static let shared = MacPairingSecurity()

    var onPairingCodeChanged: ((String) -> Void)?

    private(set) var pairingCode: String
    private(set) var pairingCodeExpiresAt: Date
    let macID: String
    private var failedAttemptTimesByDevice: [String: [Date]] = [:]
    private var globalFailedAttemptTimes: [Date] = []
    private let readCredential: (String) -> Data?
    private let writeCredential: (Data, String) -> Bool
    private let deleteCredentials: (String) -> Bool
    private let recordAuthorization: @MainActor (BridgePeerIdentity) -> Void
    private let defaults: UserDefaults
    private var credentialGeneration: String
    private let automaticallyRotate: Bool
    private var rotationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         read: @escaping (String) -> Data? = { SecureCredentialStore.data(account: $0) },
         write: @escaping (Data, String) -> Bool = { SecureCredentialStore.set($0, account: $1) },
         delete: @escaping (String) -> Bool = { SecureCredentialStore.removeAll(accountPrefix: $0) },
         authorize: @escaping @MainActor (BridgePeerIdentity) -> Void = { MacAuthorizedDeviceStore.shared.authorize($0) },
         automaticallyRotate: Bool = true) {
        self.defaults = defaults
        self.readCredential = read
        self.writeCredential = write
        self.deleteCredentials = delete
        self.recordAuthorization = authorize
        self.automaticallyRotate = automaticallyRotate
        self.credentialGeneration = defaults.string(forKey: "pairingCredentialGeneration") ?? ""
        if let saved = read("mac.identity"),
           let value = String(data: saved, encoding: .utf8),
           !value.isEmpty {
            macID = value
            // Keep a non-secret copy of the stable account name available
            // while the Mac is relaunching or the protected Keychain is
            // temporarily unavailable. The actual pairing credentials still
            // remain in SecureCredentialStore.
            defaults.set(value, forKey: "macDeviceIdentifier")
        } else if let saved = defaults.string(forKey: "macDeviceIdentifier"),
                  !saved.isEmpty {
            macID = saved
            _ = write(Data(saved.utf8), "mac.identity")
        } else {
            let value = UUID().uuidString
            macID = value
            defaults.set(value, forKey: "macDeviceIdentifier")
            _ = write(Data(value.utf8), "mac.identity")
        }
        pairingCode = PairingCode.generate()
        pairingCodeExpiresAt = Date().addingTimeInterval(PairingCode.lifetime)
        schedulePairingCodeRotation()
    }

    func requiresPairingCode(for identity: BridgePeerIdentity) -> Bool {
        return credential(for: identity) == nil
    }

    func verify(
        identity: BridgePeerIdentity,
        nonce: Data,
        proof: Data,
        channelBinding: Data
    ) -> PairingVerification {
        let now = Date()
        let attemptKey = identity.stableKey
        guard identity.isValidForAuthentication, nonce.count == 32, proof.count == 32 else {
            return PairingVerification(accepted: false, issuedCredential: nil, responseProof: nil, detail: "Invalid pairing proof.")
        }
        // Valid saved credentials must not be disabled by untrusted guesses.
        let existing = credential(for: identity)
        let savedProofValid = existing.map {
            PairingProof.verify(proof, secret: $0, role: .client, identity: identity,
                                macID: macID, nonce: nonce, channelBinding: channelBinding)
        } ?? false
        var secret = existing ?? Data()
        let isExistingCredential = savedProofValid
        if !savedProofValid {
            failedAttemptTimesByDevice = failedAttemptTimesByDevice.compactMapValues {
                let recent = $0.filter { now.timeIntervalSince($0) <= 60 }
                return recent.isEmpty ? nil : recent
            }
            globalFailedAttemptTimes.removeAll { now.timeIntervalSince($0) > 60 }
            var failures = failedAttemptTimesByDevice[attemptKey] ?? []
            guard failures.count < 5, globalFailedAttemptTimes.count < 20 else {
                return PairingVerification(accepted: false, issuedCredential: nil, responseProof: nil,
                                           detail: "Too many incorrect codes. Wait one minute and try again.")
            }
            guard now < pairingCodeExpiresAt else {
                rotatePairingCode()
                return PairingVerification(accepted: false, issuedCredential: nil, responseProof: nil,
                                           detail: "The pairing code expired. Enter the new code shown on the Mac.")
            }
            secret = Data(pairingCode.utf8)
            guard PairingProof.verify(proof, secret: secret, role: .client, identity: identity,
                                      macID: macID, nonce: nonce, channelBinding: channelBinding) else {
                failures.append(now)
                // At most 20 failed guesses can be recorded in the active window.
                failedAttemptTimesByDevice[attemptKey] = failures
                globalFailedAttemptTimes.append(now)
                return PairingVerification(accepted: false, issuedCredential: nil, responseProof: nil,
                                           detail: "The pairing proof was not accepted. Use the current Mac code to repair pairing.")
            }
        }

        let responseProof = PairingProof.make(
            secret: secret,
            role: .server,
            identity: identity,
            macID: macID,
            nonce: nonce,
            channelBinding: channelBinding
        )

        if isExistingCredential {
            failedAttemptTimesByDevice.removeValue(forKey: attemptKey)
            recordAuthorization(identity)
            return PairingVerification(
                accepted: true,
                issuedCredential: nil,
                responseProof: responseProof,
                detail: nil
            )
        }

        let credential = SecureCredentialStore.randomBytes(count: 32)
        guard writeCredential(credential, credentialAccount(for: identity)) else {
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                responseProof: nil,
                detail: "The trusted-device credential could not be saved in Keychain."
            )
        }
        recordAuthorization(identity)
        failedAttemptTimesByDevice.removeValue(forKey: attemptKey)
        rotatePairingCode()
        return PairingVerification(
            accepted: true,
            issuedCredential: credential,
            responseProof: responseProof,
            detail: nil
        )
    }

    func makeChallenge(
        for identity: BridgePeerIdentity,
        ephemeralPublicKey: Data
    ) -> PairingMessage {
        if Date() >= pairingCodeExpiresAt {
            rotatePairingCode()
        }
        return PairingMessage(
            kind: .challenge,
            protocolVersion: LANWire.securityProtocolVersion,
            macID: macID,
            nonce: SecureCredentialStore.randomBytes(count: 32),
            ephemeralPublicKey: ephemeralPublicKey,
            requiresPairingCode: requiresPairingCode(for: identity)
        )
    }

    func currentDisplayCode() -> String {
        if Date() >= pairingCodeExpiresAt {
            rotatePairingCode()
        }
        return PairingCode.formatted(pairingCode)
    }

    @discardableResult
    func forgetAllDevices() -> Bool {
        // Persist a fresh namespace BEFORE attempting deletion. Failed legacy
        // deletion must never make a revoked credential eligible after relaunch.
        credentialGeneration = UUID().uuidString
        defaults.set(credentialGeneration, forKey: "pairingCredentialGeneration")
        let persisted = defaults.synchronize()
        let deleted = deleteCredentials("mac.peer.")
        failedAttemptTimesByDevice.removeAll()
        globalFailedAttemptTimes.removeAll()
        rotatePairingCode()
        return persisted && deleted
    }

    func revokeCredential(for identity: BridgePeerIdentity) {
        SecureCredentialStore.remove(account: credentialAccount(for: identity))
    }

    private func credential(for identity: BridgePeerIdentity) -> Data? {
        readCredential(credentialAccount(for: identity))
    }

    private func credentialAccount(for identity: BridgePeerIdentity) -> String {
        credentialGeneration.isEmpty ? "mac.peer.\(identity.stableKey)" : "mac.peer.\(credentialGeneration).\(identity.stableKey)"
    }

    private func rotatePairingCode() {
        pairingCode = PairingCode.generate()
        pairingCodeExpiresAt = Date().addingTimeInterval(PairingCode.lifetime)
        onPairingCodeChanged?(PairingCode.formatted(pairingCode))
        schedulePairingCodeRotation()
    }

    private func schedulePairingCodeRotation() {
        guard automaticallyRotate else { return }
        rotationTask?.cancel()
        let expiry = pairingCodeExpiresAt
        rotationTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.pairingCodeExpiresAt == expiry else { return }
            self.rotatePairingCode()
        }
    }
}

@MainActor
final class MacAuthorizedDeviceStore {
    static let shared = MacAuthorizedDeviceStore()

    private let recordsKey = "authorizedDeviceRecords"
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
        UserDefaults.standard.removeObject(forKey: "pairedPeerName")
    }

    var displaySummary: String? {
        guard !devices.isEmpty else { return nil }
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
