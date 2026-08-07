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
    // A rejected saved credential means the peer still has a stale copy of
    // our old pairing state. Require the displayed one-time code for a short
    // repair window, then replace the credential after a successful proof.
    // Keeping this state in memory avoids deleting a valid credential merely
    // because a malicious peer submitted a bad proof.
    private var repairRequiredUntilByDevice: [String: Date] = [:]
    private var rotationTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        if let saved = SecureCredentialStore.data(account: "mac.identity"),
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
            SecureCredentialStore.set(Data(saved.utf8), account: "mac.identity")
        } else {
            let value = UUID().uuidString
            macID = value
            defaults.set(value, forKey: "macDeviceIdentifier")
            SecureCredentialStore.set(Data(value.utf8), account: "mac.identity")
        }
        pairingCode = PairingCode.generate()
        pairingCodeExpiresAt = Date().addingTimeInterval(PairingCode.lifetime)
        schedulePairingCodeRotation()
    }

    func requiresPairingCode(for identity: BridgePeerIdentity) -> Bool {
        let key = identity.stableKey
        if let expiry = repairRequiredUntilByDevice[key] {
            if expiry > Date() { return true }
            repairRequiredUntilByDevice.removeValue(forKey: key)
        }
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
        let requiresRepair = isRepairRequired(for: attemptKey, now: now)
        var failedAttemptTimes = failedAttemptTimesByDevice[attemptKey, default: []]
        failedAttemptTimes.removeAll { now.timeIntervalSince($0) > 60 }
        failedAttemptTimesByDevice[attemptKey] = failedAttemptTimes
        globalFailedAttemptTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard failedAttemptTimes.count < 5,
              globalFailedAttemptTimes.count < 20 else {
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                responseProof: nil,
                detail: "Too many incorrect codes. Wait one minute and try again."
            )
        }

        var secret: Data
        var isExistingCredential: Bool
        if let existing = credential(for: identity), !requiresRepair {
            secret = existing
            isExistingCredential = true
        } else {
            guard now < pairingCodeExpiresAt else {
                rotatePairingCode()
                return PairingVerification(
                    accepted: false,
                    issuedCredential: nil,
                    responseProof: nil,
                    detail: "The pairing code expired. Enter the new code shown on the Mac."
                )
            }
            secret = Data(pairingCode.utf8)
            isExistingCredential = false
        }

        var accepted = PairingProof.verify(
            proof,
            secret: secret,
            role: .client,
            identity: identity,
            macID: macID,
            nonce: nonce,
            channelBinding: channelBinding
        )

        // A mobile build may have already removed its stale copy while this
        // Mac was restarted, so there is no in-memory repair flag yet. Treat
        // the currently displayed code as an explicit refresh request when
        // the saved proof fails. The code is short-lived and still protected
        // by the same per-device/global rate limits below.
        if !accepted,
           isExistingCredential,
           now < pairingCodeExpiresAt {
            let codeSecret = Data(pairingCode.utf8)
            if PairingProof.verify(
                proof,
                secret: codeSecret,
                role: .client,
                identity: identity,
                macID: macID,
                nonce: nonce,
                channelBinding: channelBinding
            ) {
                secret = codeSecret
                isExistingCredential = false
                accepted = true
            }
        }

        guard accepted else {
            failedAttemptTimes.append(now)
            failedAttemptTimesByDevice[attemptKey] = failedAttemptTimes
            globalFailedAttemptTimes.append(now)
            if isExistingCredential {
                repairRequiredUntilByDevice[attemptKey] = now.addingTimeInterval(5 * 60)
            }
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                responseProof: nil,
                detail: isExistingCredential
                    ? "The saved device credential was not accepted. Enter the current Mac code once to refresh this device."
                    : "The one-time pairing code was not accepted."
            )
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
            repairRequiredUntilByDevice.removeValue(forKey: attemptKey)
            failedAttemptTimesByDevice.removeValue(forKey: attemptKey)
            MacAuthorizedDeviceStore.shared.authorize(identity)
            return PairingVerification(
                accepted: true,
                issuedCredential: nil,
                responseProof: responseProof,
                detail: nil
            )
        }

        let credential = SecureCredentialStore.randomBytes(count: 32)
        guard SecureCredentialStore.set(credential, account: credentialAccount(for: identity)) else {
            return PairingVerification(
                accepted: false,
                issuedCredential: nil,
                responseProof: nil,
                detail: "The trusted-device credential could not be saved in Keychain."
            )
        }
        MacAuthorizedDeviceStore.shared.authorize(identity)
        repairRequiredUntilByDevice.removeValue(forKey: attemptKey)
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

    func forgetAllDevices() {
        SecureCredentialStore.removeAll(accountPrefix: "mac.peer.")
        failedAttemptTimesByDevice.removeAll()
        repairRequiredUntilByDevice.removeAll()
        globalFailedAttemptTimes.removeAll()
        rotatePairingCode()
    }

    func revokeCredential(for identity: BridgePeerIdentity) {
        SecureCredentialStore.remove(account: credentialAccount(for: identity))
        repairRequiredUntilByDevice.removeValue(forKey: identity.stableKey)
    }

    private func credential(for identity: BridgePeerIdentity) -> Data? {
        SecureCredentialStore.data(account: credentialAccount(for: identity))
    }

    private func credentialAccount(for identity: BridgePeerIdentity) -> String {
        "mac.peer.\(identity.stableKey)"
    }

    private func isRepairRequired(for key: String, now: Date) -> Bool {
        guard let expiry = repairRequiredUntilByDevice[key] else { return false }
        guard expiry > now else {
            repairRequiredUntilByDevice.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func rotatePairingCode() {
        pairingCode = PairingCode.generate()
        pairingCodeExpiresAt = Date().addingTimeInterval(PairingCode.lifetime)
        onPairingCodeChanged?(PairingCode.formatted(pairingCode))
        schedulePairingCodeRotation()
    }

    private func schedulePairingCodeRotation() {
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
