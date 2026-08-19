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
    var onPairingCodeRequired: ((String, String?) -> Void)?
    var onDiscoveredMacsChanged: (([String]) -> Void)?

    private let queue = DispatchQueue(
        label: "SidecarBridge.PadLAN",
        qos: .userInteractive
    )
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var bonjourHostsByMac: [String: [String]] = [:]
    private var multipeerHostsByMac: [String: [String]] = [:]
    private var selectedMacName: String?
    // Discovery is always passive. This gate is set only by selectMac(named:)
    // after the user taps Connect, so a Bonjour/AWDL result can never dial the
    // Mac merely because it was found.
    private var userRequestedConnection = false
    private var connection: NWConnection?
    private var browserRestartWorkItem: DispatchWorkItem?
    private var idleDiscoveryRefreshWorkItem: DispatchWorkItem?
    private var connectionAttemptWorkItem: DispatchWorkItem?
    private var subnetProbeStartWorkItem: DispatchWorkItem?
    private var subnetProbeBatchWorkItems: [DispatchWorkItem] = []
    private var subnetProbeConnections: [String: NWConnection] = [:]
    private var subnetProbeGeneration = 0
    private var triedCachedHostForBrowser = false
    private var nextEndpointIndex = 0
    private let idleDiscoveryRefreshInterval: TimeInterval = 12
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var secureSession: SecurePacketSession?
    private var pairingMacID: String?
    private var pairingMacName: String?
    private var pairingNonce: Data?
    private var pairingServerPublicKey: Data?
    private var pairingSecret: Data?
    private var pairingChannelBinding: Data?
    private var submittedPairingCode: String?
    private var usedSavedCredential = false
    private var receiveBuffer = Data()
    private var pendingInput = RemoteInputCoalescer()
    private var inputSendInFlight = false
    private(set) var isConnected = false

    func start() {
        queue.async { [weak self] in self?.startBrowser() }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.userRequestedConnection = false
            self.selectedMacName = nil
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

    func resumeAfterBackground() {
        queue.async { [weak self] in
            guard let self, !self.isConnected, self.userRequestedConnection else { return }
            self.browserRestartWorkItem?.cancel()
            self.browserRestartWorkItem = nil
            self.idleDiscoveryRefreshWorkItem?.cancel()
            self.idleDiscoveryRefreshWorkItem = nil
            self.connectionAttemptWorkItem?.cancel()
            self.connectionAttemptWorkItem = nil
            self.cancelSubnetProbes()
            self.connection?.cancel()
            self.clearConnection(notify: false)
            self.nextEndpointIndex = 0

            let triedRememberedHost = self.tryCachedDirectHostForResume()
            if !triedRememberedHost {
                self.connectNextAvailable()
            }
            if self.browser == nil {
                self.startBrowser()
            }

            // Give the remembered fixed-port address first chance. If it moved,
            // fall back to the already-known Bonjour endpoint without waiting
            // for a full discovery cycle.
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isConnected, self.connection == nil else { return }
                self.connectNextAvailable()
                if self.connection == nil {
                    self.scheduleSubnetProbe(after: 0.2)
                }
            }
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

    func forceReconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            print("[SidecarBridge/LAN] Forcing reconnect: \(reason)")
            self.connection?.cancel()
            self.clearConnection(notify: true, error: reason)
            self.endpoints.removeAll()
            self.nextEndpointIndex = 0
            self.scheduleBrowserRestart(after: 0.15)
        }
    }

    func send(_ message: ControlMessage) {
        guard let data = try? PacketCodec.encode(.control(message)) else { return }
        sendPacket(data)
    }

    func sendInput(_ input: RemoteInputEvent) {
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            self.pendingInput.enqueue(input)
            self.sendNextInputIfPossible()
        }
    }

    func sendFilePacket(_ transfer: FileTransferPacket) {
        guard let data = try? PacketCodec.encode(.file(transfer)) else { return }
        sendPacket(data)
    }

    func submitPairingCode(_ code: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.submittedPairingCode = PairingCode.normalize(code)
            self.sendPairingResponseIfPossible()
        }
    }

    func selectMac(named name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.userRequestedConnection = true
            self.selectedMacName = name
            self.connection?.cancel()
            self.clearConnection(notify: false)
            self.nextEndpointIndex = 0
            self.connectNextAvailable()
            self.triedCachedHostForBrowser = false
            // Do not make a stale Bonjour result block the fixed-port path. A
            // remembered host is a direct candidate even when the browser has
            // an unrelated or unresolved service endpoint in its result set.
            self.tryCachedDirectHost()
            self.scheduleSubnetProbe(after: 0.6)
        }
    }

    /// Leaves Bonjour/AWDL discovery running while removing the active dial
    /// target. This is used by the explicit-connect flow so discovering a Mac
    /// never silently opens a session.
    func clearSelectedMac() {
        queue.async { [weak self] in
            guard let self else { return }
            self.userRequestedConnection = false
            self.selectedMacName = nil
            self.connectionAttemptWorkItem?.cancel()
            self.connectionAttemptWorkItem = nil
            self.cancelSubnetProbes()
            self.connection?.cancel()
            self.clearConnection(notify: false)
            self.nextEndpointIndex = 0
        }
    }

    /// Keeps direct candidates learned through the nearby Multipeer
    /// advertisement. This is useful when an access point filters Bonjour
    /// multicast but still permits a unicast TCP connection.
    func setMultipeerAdvertisedHosts(_ hosts: [String], forMacName name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.multipeerHostsByMac[name] = hosts
            if self.selectedMacName == name,
               !self.isConnected,
               self.connection == nil {
                self.connectNextAvailable()
            }
        }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        triedCachedHostForBrowser = false
        let parameters = lowLatencyParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BridgeConstants.lanServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            print("[SidecarBridge/LAN] Bonjour results: \(results.count)")
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                if case let .bonjour(txtRecord) = result.metadata {
                    let protocolVersion = txtRecord[BridgeConstants.protocolTXTKey] ?? "unknown"
                    let build = txtRecord[BridgeConstants.buildTXTKey] ?? "unknown"
                    print("[SidecarBridge/LAN] \(name) advertises protocol \(protocolVersion), build \(build)")
                }
            }
            self.endpoints = results.map(\.endpoint)
            var bonjourHosts: [String: [String]] = [:]
            let names = self.endpoints.compactMap { endpoint -> String? in
                guard case let .service(name, _, _, _) = endpoint else { return nil }
                return name
            }
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                if case let .bonjour(txtRecord) = result.metadata {
                    bonjourHosts[name] = BridgeNetworkMetadata.decodePrivateIPv4Addresses(
                        txtRecord[BridgeConstants.hostsTXTKey]
                    )
                }
            }
            self.bonjourHostsByMac = bonjourHosts
            DispatchQueue.main.async {
                self.onDiscoveredMacsChanged?(Array(Set(names)).sorted())
            }
            if self.hasSelectableDirectCandidate {
                self.cancelSubnetProbes()
                self.idleDiscoveryRefreshWorkItem?.cancel()
                self.idleDiscoveryRefreshWorkItem = nil
                self.browserRestartWorkItem?.cancel()
                self.browserRestartWorkItem = nil
            } else {
                self.scheduleIdleDiscoveryRefresh()
                self.tryCachedDirectHost()
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
                if !self.hasSelectableDirectCandidate {
                    self.tryCachedDirectHost()
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
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.tryCachedDirectHost()
        }
    }

    private func connectNextAvailable() {
        guard userRequestedConnection, connection == nil, let selectedMacName else { return }
        let serviceEndpoints = endpoints.filter {
            guard case let .service(name, _, _, _) = $0 else { return false }
            return name == selectedMacName
        }
        let advertisedHosts = (multipeerHostsByMac[selectedMacName] ?? []) +
            (bonjourHostsByMac[selectedMacName] ?? [])
        let port = NWEndpoint.Port(rawValue: BridgeConstants.directPort)
        var selectableEndpoints: [NWEndpoint] = []
        if let port {
            selectableEndpoints.append(contentsOf: advertisedHosts.map {
                .hostPort(host: NWEndpoint.Host($0), port: port)
            })
        }
        selectableEndpoints.append(contentsOf: serviceEndpoints)
        var seen = Set<String>()
        selectableEndpoints = selectableEndpoints.filter { endpoint in
            let key = String(describing: endpoint)
            return seen.insert(key).inserted
        }
        guard !selectableEndpoints.isEmpty else { return }
        if nextEndpointIndex >= selectableEndpoints.count { nextEndpointIndex = 0 }
        let endpoint = selectableEndpoints[nextEndpointIndex]
        print("[SidecarBridge/LAN] Connecting to \(endpoint)")
        nextEndpointIndex = (nextEndpointIndex + 1) % selectableEndpoints.count
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
                if let host = Self.privateIPv4Host(connection.currentPath?.remoteEndpoint)
                    ?? Self.privateIPv4Host(endpoint) {
                    // Keep the last dialable address even when this session
                    // arrived through Bonjour. If multicast is filtered on the
                    // next launch, the iPad can still start a direct attempt.
                    UserDefaults.standard.set(host, forKey: "lastDirectMacHost")
                }
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
                protocolVersion: LANWire.securityProtocolVersion,
                deviceName: PadDeviceIdentity.current.deviceName,
                publicKey: privateKey.publicKey.rawRepresentation,
                deviceID: PadDeviceIdentity.current.deviceID,
                deviceKind: PadDeviceIdentity.current.deviceKind
            )
            connection.send(
                content: try LANWire.handshake(hello, marker: LANWire.clientHello),
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    self.queue.async {
                        // A delayed callback from an abandoned dial must not
                        // tear down the newer connection that replaced it.
                        guard self.connection === connection else { return }
                        if let error {
                            self.clearConnection(notify: true, error: error.localizedDescription)
                            self.retrySoon()
                        }
                    }
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
        if secureSession == nil {
            let response = try LANWire.decodeHandshake(payload, marker: LANWire.serverHello)
            guard let privateKey else { return }
            let clientPublicKey = privateKey.publicKey.rawRepresentation
            secureSession = try LANWire.secureSession(
                privateKey: privateKey,
                peerPublicKey: response.publicKey,
                clientPublicKey: clientPublicKey,
                serverPublicKey: response.publicKey,
                role: .client
            )
            guard let macID = response.macID,
                  let nonce = response.authNonce else {
                throw LANWire.LANError.authenticationFailed
            }
            pairingMacID = macID
            pairingMacName = response.deviceName
            pairingNonce = nonce
            pairingServerPublicKey = response.publicKey
            sendPairingResponseIfPossible()
            return
        }

        guard let secureSession else { return }
        let packet = try PacketCodec.decode(LANWire.decrypt(payload, session: secureSession))
        switch packet {
        case .authentication(let message):
            handleAuthentication(message)
        case .control(let command):
            guard isConnected else { return }
            DispatchQueue.main.async { self.onCommand?(command) }
        case .jpeg(let frame):
            guard isConnected else { return }
            DispatchQueue.main.async { self.onFrame?(frame) }
        case .video(let frame):
            guard isConnected else { return }
            DispatchQueue.main.async { self.onVideoFrame?(frame) }
        case .file(let transfer):
            guard isConnected else { return }
            DispatchQueue.main.async { self.onFilePacket?(transfer) }
        }
    }

    private func sendPairingResponseIfPossible() {
        guard !isConnected,
              let macID = pairingMacID,
              let nonce = pairingNonce,
              let clientPublicKey = privateKey?.publicKey.rawRepresentation,
              let serverPublicKey = pairingServerPublicKey else { return }
        let identity = PadDeviceIdentity.current

        let account = "pad.mac.\(macID)"
        let secret: Data
        if let credential = SecureCredentialStore.data(account: account) {
            secret = credential
            usedSavedCredential = true
        } else if let code = submittedPairingCode, code.count == PairingCode.characterCount {
            secret = Data(code.utf8)
            usedSavedCredential = false
        } else {
            DispatchQueue.main.async {
                self.onPairingCodeRequired?(
                    self.pairingMacName ?? "Mac",
                    self.submittedPairingCode == nil
                        ? nil
                        : "Enter the complete 16-digit code shown on the Mac."
                )
            }
            return
        }

        let channelBinding = PairingProof.lanChannelBinding(
            clientPublicKey: clientPublicKey,
            serverPublicKey: serverPublicKey
        )
        pairingSecret = secret
        pairingChannelBinding = channelBinding
        let proof = PairingProof.make(
            secret: secret,
            role: .client,
            identity: identity,
            macID: macID,
            nonce: nonce,
            channelBinding: channelBinding
        )
        sendAuthentication(PairingMessage(
            kind: .response,
            protocolVersion: LANWire.securityProtocolVersion,
            identity: identity,
            proof: proof
        ))
    }

    private func handleAuthentication(_ message: PairingMessage) {
        switch message.kind {
        case .accepted:
            guard message.protocolVersion == LANWire.securityProtocolVersion,
                  let proof = message.proof,
                  let secret = pairingSecret,
                  let macID = pairingMacID,
                  let nonce = pairingNonce,
                  let channelBinding = pairingChannelBinding,
                  PairingProof.verify(
                    proof,
                    secret: secret,
                    role: .server,
                    identity: PadDeviceIdentity.current,
                    macID: macID,
                    nonce: nonce,
                    channelBinding: channelBinding
                  ) else {
                connection?.cancel()
                clearConnection(
                    notify: true,
                    error: LANWire.LANError.authenticationFailed.localizedDescription
                )
                return
            }
            if let credential = message.credential, let macID = pairingMacID {
                guard SecureCredentialStore.set(credential, account: "pad.mac.\(macID)") else {
                    clearConnection(
                        notify: true,
                        error: "The trusted Mac credential could not be saved in Keychain. Use Forget All on the Mac, then pair again."
                    )
                    return
                }
            }
            isConnected = true
            submittedPairingCode = nil
            pairingSecret = nil
            print("[SidecarBridge/LAN] Trusted encrypted handshake complete with \(pairingMacName ?? "Mac")")
            notify(connected: true, value: "LAN:\(pairingMacName ?? "Mac")")
        case .rejected:
            // The Mac has explicitly told us that the saved credential is
            // stale. Remove only this Mac's entry so the next submission uses
            // the displayed one-time code instead of retrying the same bad
            // credential forever. The Mac will issue a replacement credential
            // after that one successful repair proof.
            if usedSavedCredential, let macID = pairingMacID {
                SecureCredentialStore.remove(account: "pad.mac.\(macID)")
                usedSavedCredential = false
            }
            submittedPairingCode = nil
            pairingSecret = nil
            DispatchQueue.main.async {
                self.onPairingCodeRequired?(
                    self.pairingMacName ?? "Mac",
                    message.detail ?? "The one-time code was not accepted."
                )
            }
        case .challenge, .response:
            break
        }
    }

    private func sendAuthentication(_ message: PairingMessage) {
        do {
            guard let connection, let secureSession else { return }
            let packet = try PacketCodec.encode(.authentication(message))
            connection.send(
                content: try LANWire.encrypted(packet, session: secureSession),
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    self.queue.async {
                        guard self.connection === connection else { return }
                        if let error {
                            self.clearConnection(notify: true, error: error.localizedDescription)
                            self.retrySoon()
                        }
                    }
                }
            )
        } catch {
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func sendPacket(_ packet: Data) {
        queue.async { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connection,
                  let secureSession = self.secureSession else { return }
            do {
            connection.send(
                content: try LANWire.encrypted(packet, session: secureSession),
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    self.queue.async {
                        guard self.connection === connection else { return }
                        if let error {
                            self.clearConnection(notify: true, error: error.localizedDescription)
                            self.retrySoon()
                        }
                    }
                }
            )
            } catch {
                self.clearConnection(notify: true, error: error.localizedDescription)
            }
        }
    }

    private func sendNextInputIfPossible() {
        guard !inputSendInFlight,
              isConnected,
              let connection,
              let secureSession,
              let input = pendingInput.popFirst() else { return }
        guard let message = ControlMessage.input(input),
              let packet = try? PacketCodec.encode(.control(message)) else {
            sendNextInputIfPossible()
            return
        }

        let sendsImmediately = input.isCoalescibleInput
        do {
            // Pointer/scroll updates are already coalesced upstream. Do not
            // make the next update wait for NWConnection's contentProcessed
            // callback (which can be delayed by TCP buffering); ordered key
            // and button packets still use the acknowledgement gate below.
            inputSendInFlight = !sendsImmediately
            connection.send(
                content: try LANWire.encrypted(packet, session: secureSession),
                completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self else { return }
                    self.queue.async {
                        guard let connection, self.connection === connection else { return }
                        if let error {
                            self.clearConnection(notify: true, error: error.localizedDescription)
                        } else if !sendsImmediately {
                            self.inputSendInFlight = false
                            self.sendNextInputIfPossible()
                        }
                    }
                }
            )
            if sendsImmediately {
                sendNextInputIfPossible()
            }
        } catch {
            inputSendInFlight = false
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.userRequestedConnection, !self.isConnected, self.connection == nil else { return }
            self.connectNextAvailable()
            if self.connection == nil {
                self.tryCachedDirectHost()
                self.scheduleSubnetProbe(after: 0.2)
            }
        }
    }

    /// Bonjour can be filtered by some access points even when devices can
    /// still open normal TCP connections to one another. Probe a fixed,
    /// encrypted SidecarBridge port on the iPad's local /24 as a bounded
    /// discovery fallback. It is also allowed after an unresolved Bonjour
    /// result so one stale service endpoint cannot strand the connection state.
    /// The normal Curve25519 handshake and Mac pairing approval still run
    /// before any app data is accepted.
    private func scheduleSubnetProbe(after delay: TimeInterval) {
        guard userRequestedConnection,
              !isConnected,
              connection == nil,
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
        guard userRequestedConnection, !isConnected, connection == nil else { return }
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
                  self.userRequestedConnection,
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

    private func tryCachedDirectHost() {
        guard userRequestedConnection,
              selectedMacName != nil,
              !triedCachedHostForBrowser,
              !isConnected,
              connection == nil,
              subnetProbeConnections.isEmpty,
              let host = UserDefaults.standard.string(forKey: "lastDirectMacHost"),
              Self.isPrivateIPv4Address(host),
              let port = NWEndpoint.Port(rawValue: BridgeConstants.directPort) else { return }
        triedCachedHostForBrowser = true
        subnetProbeGeneration &+= 1
        let generation = subnetProbeGeneration
        print("[SidecarBridge/LAN] Trying last successful Mac address \(host)")
        probe(host: host, port: port, generation: generation)
    }

    @discardableResult
    private func tryCachedDirectHostForResume() -> Bool {
        guard userRequestedConnection,
              selectedMacName != nil,
              !isConnected,
              connection == nil,
              let host = UserDefaults.standard.string(forKey: "lastDirectMacHost"),
              Self.isPrivateIPv4Address(host),
              let port = NWEndpoint.Port(rawValue: BridgeConstants.directPort) else {
            return false
        }
        triedCachedHostForBrowser = true
        subnetProbeGeneration &+= 1
        let generation = subnetProbeGeneration
        print("[SidecarBridge/LAN] Fast-resuming last Mac address \(host)")
        probe(host: host, port: port, generation: generation)
        return true
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
        UserDefaults.standard.set(host, forKey: "lastDirectMacHost")
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

    private static func isPrivateIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 &&
            parts.allSatisfy { (0...255).contains($0) } &&
            isPrivateIPv4(parts)
    }

    private static func privateIPv4Host(_ endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let value = String(describing: host)
        return isPrivateIPv4Address(value) ? value : nil
    }

    /// Bonjour can remain in `.ready` with an empty, stale result set after a
    /// Wi-Fi or AWDL transition. Recreating the browser forces mDNS discovery
    /// without requiring the user to close and reopen the iPad app.
    private func scheduleIdleDiscoveryRefresh() {
        guard !isConnected, !hasSelectableDirectCandidate, idleDiscoveryRefreshWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected, !self.hasSelectableDirectCandidate else { return }
            self.idleDiscoveryRefreshWorkItem = nil
            print("[SidecarBridge/LAN] No Bonjour results; refreshing browser")
            self.browser?.cancel()
            self.browser = nil
            self.startBrowser()
        }
        idleDiscoveryRefreshWorkItem = workItem
        queue.asyncAfter(deadline: .now() + idleDiscoveryRefreshInterval, execute: workItem)
    }

    /// Whether the currently selected Mac has an endpoint or private IPv4
    /// address we can actually dial. `endpoints` may contain another Mac or a
    /// stale service, so checking only whether the browser result list is
    /// non-empty is not sufficient.
    private var hasSelectableDirectCandidate: Bool {
        guard let selectedMacName else { return false }
        let hasService = endpoints.contains {
            guard case let .service(name, _, _, _) = $0 else { return false }
            return name == selectedMacName
        }
        return hasService ||
            !(bonjourHostsByMac[selectedMacName] ?? []).isEmpty ||
            !(multipeerHostsByMac[selectedMacName] ?? []).isEmpty
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
        // A Wi-Fi-to-AWDL path can spend several seconds in preparing while
        // iPadOS changes interfaces. Four seconds caused false failures that
        // looked like a bad pairing or an unavailable Mac; allow the path to
        // settle before rebuilding discovery.
        connectionAttemptWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 8, execute: workItem)
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
        secureSession = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        pendingInput.removeAll()
        inputSendInFlight = false
        pairingMacID = nil
        pairingMacName = nil
        pairingNonce = nil
        pairingServerPublicKey = nil
        pairingSecret = nil
        pairingChannelBinding = nil
        submittedPairingCode = nil
        usedSavedCredential = false
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
        tcp.disableAckStretching = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 4
        tcp.connectionDropTime = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }
}
