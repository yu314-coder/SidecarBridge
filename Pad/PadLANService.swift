import CryptoKit
import Darwin
import Foundation
import Network
import UIKit

final class PadLANService {
    var onFrame: ((Data) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onCommand: ((ControlMessage) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?

    private let queue = DispatchQueue(label: "SidecarBridge.PadLAN")
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var connection: NWConnection?
    private var browserRestartWorkItem: DispatchWorkItem?
    private var idleDiscoveryRefreshWorkItem: DispatchWorkItem?
    private var connectionAttemptWorkItem: DispatchWorkItem?
    private var subnetProbeStartWorkItem: DispatchWorkItem?
    private var subnetProbeBatchWorkItems: [DispatchWorkItem] = []
    private var subnetProbeConnections: [String: NWConnection] = [:]
    private var subnetProbeGeneration = 0
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
            self.cancelSubnetProbes()
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
            self?.cancelSubnetProbes()
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

    func sendFilePacket(_ transfer: FileTransferPacket) {
        guard let data = try? PacketCodec.encode(.file(transfer)) else { return }
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
                self.cancelSubnetProbes()
                self.idleDiscoveryRefreshWorkItem?.cancel()
                self.idleDiscoveryRefreshWorkItem = nil
                self.browserRestartWorkItem?.cancel()
                self.browserRestartWorkItem = nil
            } else {
                self.scheduleIdleDiscoveryRefresh()
                self.scheduleSubnetProbe(after: 1.5)
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
                if self.endpoints.isEmpty {
                    self.scheduleIdleDiscoveryRefresh()
                    self.scheduleSubnetProbe(after: 1.5)
                }
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
        case .file(let transfer):
            DispatchQueue.main.async { self.onFilePacket?(transfer) }
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

    /// Bonjour can be filtered by some access points even when devices can
    /// still open normal TCP connections to one another. Probe a fixed,
    /// encrypted SidecarBridge port on the iPad's local /24 as a bounded
    /// discovery fallback. The normal Curve25519 handshake and Mac pairing
    /// approval still run before any app data is accepted.
    private func scheduleSubnetProbe(after delay: TimeInterval) {
        guard !isConnected,
              connection == nil,
              endpoints.isEmpty,
              subnetProbeStartWorkItem == nil,
              subnetProbeConnections.isEmpty else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.subnetProbeStartWorkItem = nil
            self.startSubnetProbe()
        }
        subnetProbeStartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startSubnetProbe() {
        guard !isConnected, connection == nil, endpoints.isEmpty else { return }
        let hosts = Self.privateIPv4ProbeHosts()
        guard !hosts.isEmpty,
              let port = NWEndpoint.Port(rawValue: BridgeConstants.directPort) else { return }

        subnetProbeGeneration &+= 1
        let generation = subnetProbeGeneration
        notify(
            connected: false,
            value: "Bonjour is empty; probing the encrypted same-Wi-Fi fallback."
        )

        let batchSize = 24
        for offset in stride(from: 0, to: hosts.count, by: batchSize) {
            let batch = Array(hosts[offset..<min(offset + batchSize, hosts.count)])
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.subnetProbeGeneration == generation,
                      !self.isConnected,
                      self.connection == nil else { return }
                for host in batch {
                    self.probe(host: host, port: port, generation: generation)
                }
            }
            subnetProbeBatchWorkItems.append(workItem)
            let batchIndex = offset / batchSize
            queue.asyncAfter(deadline: .now() + (Double(batchIndex) * 0.25), execute: workItem)
        }

        let batchCount = Int(ceil(Double(hosts.count) / Double(batchSize)))
        let finish = DispatchWorkItem { [weak self] in
            guard let self,
                  self.subnetProbeGeneration == generation,
                  !self.isConnected,
                  self.connection == nil else { return }
            self.cancelSubnetProbes()
            self.notify(
                connected: false,
                value: "No direct address answered; Bonjour and nearby P2P remain active."
            )
            self.scheduleSubnetProbe(after: 12)
        }
        subnetProbeBatchWorkItems.append(finish)
        queue.asyncAfter(
            deadline: .now() + (Double(batchCount) * 0.25) + 1.2,
            execute: finish
        )
    }

    private func probe(host: String, port: NWEndpoint.Port, generation: Int) {
        guard subnetProbeConnections[host] == nil else { return }
        let probe = NWConnection(host: NWEndpoint.Host(host), port: port, using: lowLatencyParameters())
        subnetProbeConnections[host] = probe
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            guard let self,
                  let probe,
                  self.subnetProbeGeneration == generation else { return }
            switch state {
            case .ready:
                self.promoteSubnetProbe(probe, host: host)
            case .failed, .cancelled:
                if self.subnetProbeConnections[host] === probe {
                    self.subnetProbeConnections.removeValue(forKey: host)
                }
            default:
                break
            }
        }
        probe.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.9) { [weak self, weak probe] in
            guard let self,
                  let probe,
                  self.subnetProbeGeneration == generation,
                  self.subnetProbeConnections[host] === probe else { return }
            self.subnetProbeConnections.removeValue(forKey: host)
            probe.cancel()
        }
    }

    private func promoteSubnetProbe(_ directConnection: NWConnection, host: String) {
        guard connection == nil, !isConnected else {
            directConnection.cancel()
            return
        }

        cancelSubnetProbes(except: directConnection)
        print("[SidecarBridge/LAN] Fixed-port fallback found \(host):\(BridgeConstants.directPort)")
        connection = directConnection
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        directConnection.stateUpdateHandler = { [weak self, weak directConnection] state in
            guard let self,
                  let directConnection,
                  self.connection === directConnection else { return }
            switch state {
            case .failed(let error):
                self.clearConnection(notify: true, error: error.localizedDescription)
                self.scheduleSubnetProbe(after: 1)
            case .cancelled:
                self.clearConnection(notify: true)
                self.scheduleSubnetProbe(after: 1)
            default:
                break
            }
        }
        beginHandshake(on: directConnection)
        receive(on: directConnection)
    }

    private func cancelSubnetProbes(except retained: NWConnection? = nil) {
        subnetProbeGeneration &+= 1
        subnetProbeStartWorkItem?.cancel()
        subnetProbeStartWorkItem = nil
        subnetProbeBatchWorkItems.forEach { $0.cancel() }
        subnetProbeBatchWorkItems.removeAll(keepingCapacity: true)
        for probe in subnetProbeConnections.values where probe !== retained {
            probe.cancel()
        }
        subnetProbeConnections.removeAll(keepingCapacity: true)
    }

    private static func privateIPv4ProbeHosts() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var localAddresses: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: host)
            let parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4,
                  parts.allSatisfy({ (0...255).contains($0) }),
                  isPrivateIPv4(parts) else { continue }
            localAddresses.append(value)
        }

        var hosts: [String] = []
        var seen = Set<String>()
        for localAddress in localAddresses {
            let parts = localAddress.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            for suffix in 1...254 {
                let candidate = "\(prefix).\(suffix)"
                guard candidate != localAddress, seen.insert(candidate).inserted else { continue }
                hosts.append(candidate)
            }
        }
        return hosts
    }

    private static func isPrivateIPv4(_ parts: [Int]) -> Bool {
        parts[0] == 10 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168)
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
        cancelSubnetProbes()
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
