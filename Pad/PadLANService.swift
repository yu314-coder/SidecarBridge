import CryptoKit
import Foundation
import Network
import UIKit

final class PadLANService {
    var onFrame: ((Data) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onCommand: ((ControlMessage) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?

    private let queue = DispatchQueue(label: "SidecarBridge.PadLAN")
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var connection: NWConnection?
    private var browserRestartWorkItem: DispatchWorkItem?
    private var idleDiscoveryRefreshWorkItem: DispatchWorkItem?
    private var connectionAttemptWorkItem: DispatchWorkItem?
    private var nextEndpointIndex = 0
    private let idleDiscoveryRefreshInterval: TimeInterval = 30
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var receiveBuffer = Data()
    private(set) var isConnected = false

    func start() {
        queue.async { [weak self] in self?.startBrowser() }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browserRestartWorkItem?.cancel()
            self.browserRestartWorkItem = nil
            self.idleDiscoveryRefreshWorkItem?.cancel()
            self.idleDiscoveryRefreshWorkItem = nil
            self.connectionAttemptWorkItem?.cancel()
            self.connectionAttemptWorkItem = nil
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.clearConnection(notify: false)
            self.endpoints.removeAll()
            self.nextEndpointIndex = 0
            self.startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.browserRestartWorkItem?.cancel()
            self?.browserRestartWorkItem = nil
            self?.idleDiscoveryRefreshWorkItem?.cancel()
            self?.idleDiscoveryRefreshWorkItem = nil
            self?.connectionAttemptWorkItem?.cancel()
            self?.connectionAttemptWorkItem = nil
            self?.browser?.cancel()
            self?.browser = nil
            self?.connection?.cancel()
            self?.clearConnection(notify: false)
        }
    }

    func send(_ message: ControlMessage) {
        guard let data = try? PacketCodec.encode(.control(message)) else { return }
        sendPacket(data)
    }

    func sendInput(_ input: RemoteInputEvent) {
        guard let message = ControlMessage.input(input),
              let data = try? PacketCodec.encode(.control(message)) else { return }
        sendPacket(data)
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let parameters = lowLatencyParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: BridgeConstants.lanServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            print("[SidecarBridge/LAN] Bonjour results: \(results.count)")
            self.endpoints = results.map(\.endpoint)
            if !self.endpoints.isEmpty {
                self.idleDiscoveryRefreshWorkItem?.cancel()
                self.idleDiscoveryRefreshWorkItem = nil
                self.browserRestartWorkItem?.cancel()
                self.browserRestartWorkItem = nil
            } else {
                self.scheduleIdleDiscoveryRefresh()
            }
            self.connectNextAvailable()
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            print("[SidecarBridge/LAN] Browser state: \(state)")
            switch state {
            case .ready:
                self.browserRestartWorkItem?.cancel()
                self.browserRestartWorkItem = nil
                self.notifyLocalNetwork(.granted)
                if self.endpoints.isEmpty { self.scheduleIdleDiscoveryRefresh() }
            case .failed(let error):
                let access = self.accessState(for: error)
                self.notifyLocalNetwork(access)
                self.notify(connected: false, value: "Same-Wi-Fi discovery: \(error.localizedDescription)")
                browser.cancel()
                if self.browser === browser { self.browser = nil }
                if case .denied = access { break }
                self.scheduleBrowserRestart(after: 1)
            case .waiting(let error):
                let access = self.accessState(for: error)
                self.notifyLocalNetwork(access)
                if case .denied = access {
                    self.browserRestartWorkItem?.cancel()
                    self.browserRestartWorkItem = nil
                } else {
                    self.scheduleBrowserRestart(after: 5)
                }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func connectNextAvailable() {
        guard connection == nil, !endpoints.isEmpty else { return }
        if nextEndpointIndex >= endpoints.count { nextEndpointIndex = 0 }
        let endpoint = endpoints[nextEndpointIndex]
        print("[SidecarBridge/LAN] Connecting to \(endpoint)")
        nextEndpointIndex = (nextEndpointIndex + 1) % endpoints.count
        let parameters = lowLatencyParameters()
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        armConnectionAttemptTimeout(for: connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            print("[SidecarBridge/LAN] Connection state: \(state)")
            switch state {
            case .ready:
                self.connectionAttemptWorkItem?.cancel()
                self.connectionAttemptWorkItem = nil
                self.beginHandshake(on: connection)
                self.receive(on: connection)
            case .failed(let error):
                self.connectionAttemptWorkItem?.cancel()
                self.connectionAttemptWorkItem = nil
                self.clearConnection(notify: true, error: error.localizedDescription)
                self.retrySoon()
            case .cancelled:
                self.connectionAttemptWorkItem?.cancel()
                self.connectionAttemptWorkItem = nil
                self.clearConnection(notify: true)
                self.retrySoon()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func beginHandshake(on connection: NWConnection) {
        do {
            guard let privateKey else { return }
            let hello = LANHandshake(
                deviceName: UIDevice.current.name,
                publicKey: privateKey.publicKey.rawRepresentation
            )
            connection.send(
                content: try LANWire.handshake(hello, marker: LANWire.clientHello),
                completion: .contentProcessed { [weak self] error in
                    if let error { self?.clearConnection(notify: true, error: error.localizedDescription) }
                }
            )
        } catch {
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func receive(on activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak activeConnection] data, _, complete, error in
            guard let self, let activeConnection, self.connection === activeConnection else { return }
            if let data { self.receiveBuffer.append(data) }
            do {
                for payload in try LANWire.takeFrames(from: &self.receiveBuffer) {
                    try self.handle(payload)
                }
            } catch {
                activeConnection.cancel()
                self.clearConnection(notify: true, error: error.localizedDescription)
                return
            }
            if let error {
                self.clearConnection(notify: true, error: error.localizedDescription)
                self.retrySoon()
            } else if complete {
                self.clearConnection(notify: true)
                self.retrySoon()
            } else {
                self.receive(on: activeConnection)
            }
        }
    }

    private func handle(_ payload: Data) throws {
        if sessionKey == nil {
            let response = try LANWire.decodeHandshake(payload, marker: LANWire.serverHello)
            guard let privateKey else { return }
            let clientPublicKey = privateKey.publicKey.rawRepresentation
            sessionKey = try LANWire.sessionKey(
                privateKey: privateKey,
                peerPublicKey: response.publicKey,
                clientPublicKey: clientPublicKey,
                serverPublicKey: response.publicKey
            )
            isConnected = true
            print("[SidecarBridge/LAN] Encrypted handshake complete with \(response.deviceName)")
            notify(connected: true, value: "LAN:\(response.deviceName)")
            return
        }

        guard let sessionKey else { return }
        let packet = try PacketCodec.decode(LANWire.decrypt(payload, key: sessionKey))
        switch packet {
        case .control(let command):
            DispatchQueue.main.async { self.onCommand?(command) }
        case .jpeg(let frame):
            DispatchQueue.main.async { self.onFrame?(frame) }
        case .video(let frame):
            DispatchQueue.main.async { self.onVideoFrame?(frame) }
        }
    }

    private func sendPacket(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, self.isConnected, let connection = self.connection, let key = self.sessionKey else { return }
            do {
                connection.send(
                    content: try LANWire.encrypted(packet, key: key),
                    completion: .contentProcessed { [weak self] error in
                        if let error { self?.clearConnection(notify: true, error: error.localizedDescription) }
                    }
                )
            } catch {
                self.clearConnection(notify: true, error: error.localizedDescription)
            }
        }
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectNextAvailable() }
    }

    /// Bonjour can remain in `.ready` with an empty, stale result set after a
    /// Wi-Fi or AWDL transition. Recreating the browser forces mDNS discovery
    /// without requiring the user to close and reopen the iPad app.
    private func scheduleIdleDiscoveryRefresh() {
        guard !isConnected, endpoints.isEmpty, idleDiscoveryRefreshWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected, self.endpoints.isEmpty else { return }
            self.idleDiscoveryRefreshWorkItem = nil
            print("[SidecarBridge/LAN] No Bonjour results; refreshing browser")
            self.browser?.cancel()
            self.browser = nil
            self.startBrowser()
        }
        idleDiscoveryRefreshWorkItem = workItem
        queue.asyncAfter(deadline: .now() + idleDiscoveryRefreshInterval, execute: workItem)
    }

    /// A Bonjour endpoint may survive while its route has gone stale. Do not
    /// let one unresolved endpoint block both direct and nearby recovery.
    private func armConnectionAttemptTimeout(for activeConnection: NWConnection) {
        connectionAttemptWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak activeConnection] in
            guard let self,
                  let activeConnection,
                  self.connection === activeConnection,
                  !self.isConnected else { return }
            print("[SidecarBridge/LAN] Connection attempt timed out; rebuilding discovery")
            activeConnection.cancel()
            self.clearConnection(notify: true, error: "Direct connection timed out; refreshing discovery.")
            self.endpoints.removeAll()
            self.nextEndpointIndex = 0
            self.scheduleBrowserRestart(after: 0.25)
        }
        connectionAttemptWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 7, execute: workItem)
    }

    private func scheduleBrowserRestart(after delay: TimeInterval) {
        browserRestartWorkItem?.cancel()
        idleDiscoveryRefreshWorkItem?.cancel()
        idleDiscoveryRefreshWorkItem = nil
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected else { return }
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.clearConnection(notify: false)
            self.endpoints.removeAll()
            self.nextEndpointIndex = 0
            self.startBrowser()
        }
        browserRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearConnection(notify shouldNotify: Bool, error: String? = nil) {
        let wasConnected = isConnected
        connectionAttemptWorkItem?.cancel()
        connectionAttemptWorkItem = nil
        connection = nil
        privateKey = nil
        sessionKey = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        isConnected = false
        if shouldNotify && (wasConnected || error != nil) { notify(connected: false, value: error) }
    }

    private func notify(connected: Bool, value: String?) {
        DispatchQueue.main.async { self.onConnectionChanged?(connected, value) }
    }

    private func notifyLocalNetwork(_ state: LocalNetworkAccessState) {
        DispatchQueue.main.async { self.onLocalNetworkStateChanged?(state) }
    }

    private func accessState(for error: Error) -> LocalNetworkAccessState {
        let description = String(describing: error) + " " + error.localizedDescription
        if description.localizedCaseInsensitiveContains("NoAuth") ||
            description.localizedCaseInsensitiveContains("PolicyDenied") ||
            description.localizedCaseInsensitiveContains("not authorized") {
            return .denied
        }
        return .unavailable(error.localizedDescription)
    }

    private func lowLatencyParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }
}
