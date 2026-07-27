import Foundation
import LocalAuthentication

struct MacAuthorizedDevice: Codable, Equatable {
    let deviceID: String
    var deviceName: String
    var deviceKind: String
    let authorizedAt: Date
    var lastSeenAt: Date
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
