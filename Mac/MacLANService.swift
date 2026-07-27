import AppKit
import CryptoKit
import Foundation
import Network

final class MacLANService {
    var onCommand: ((ControlMessage) -> Void)?
    var onInput: ((RemoteInputEvent) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?

    private let queue = DispatchQueue(
        label: "SidecarBridge.MacLAN",
        qos: .userInteractive
    )
    private var listener: NWListener?
    private var listenerRestartWorkItem: DispatchWorkItem?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var connection: NWConnection?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var pendingIdentity: BridgePeerIdentity?
    private var authenticationNonce: Data?
    private var pendingClientPublicKey: Data?
    private var pendingServerPublicKey: Data?
    private var receiveBuffer = Data()
    private struct PendingVideo {
        let sequence: UInt64
        let isKeyFrame: Bool
        let packet: Data
    }

    private var sendingFrame = false
    private var waitingForKeyFrame = false
    private var inFlightVideoSequence: UInt64?
    private var pendingVideo: [PendingVideo] = []
    private(set) var isConnected = false

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listenerRestartWorkItem?.cancel()
            self?.listenerRestartWorkItem = nil
            self?.handshakeTimeoutWorkItem?.cancel()
            self?.handshakeTimeoutWorkItem = nil
            self?.listener?.cancel()
            self?.listener = nil
            self?.connection?.cancel()
            self?.clearConnection(notify: false)
        }
    }

    func forceDisconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            print("[SidecarBridge/LAN] Dropping stale iPad connection: \(reason)")
            self.connection?.cancel()
            self.clearConnection(notify: true, error: reason)
        }
    }

    func send(_ message: ControlMessage) {
        guard let data = try? PacketCodec.encode(.control(message)) else { return }
        sendPacket(data, isFrame: false)
    }

    func sendFilePacket(_ transfer: FileTransferPacket) {
        guard let data = try? PacketCodec.encode(.file(transfer)) else { return }
        sendPacket(data, isFrame: false)
    }

    func sendFrame(_ jpeg: Data) {
        guard let data = try? PacketCodec.encode(.jpeg(jpeg)) else { return }
        sendPacket(data, isFrame: true)
    }

    func sendVideoFrame(_ frame: VideoFrame) {
        guard let data = try? PacketCodec.encode(.video(frame)) else { return }
        queue.async { [weak self] in
            self?.enqueueVideo(PendingVideo(
                sequence: frame.sequence,
                isKeyFrame: frame.isKeyFrame,
                packet: data
            ))
        }
    }

    func acknowledgeVideo(sequence: UInt64) {
        // Direct Network.framework delivery is paced by contentProcessed.
        // Waiting for an app-level round trip limited some local links to
        // roughly four frames per second. Keep ACK decoding for compatibility,
        // but do not let it open another concurrent TCP send.
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let parameters = lowLatencyParameters()
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            guard let port = NWEndpoint.Port(rawValue: BridgeConstants.directPort) else {
                throw POSIXError(.EINVAL)
            }
            let listener = try NWListener(using: parameters, on: port)
            let name = Host.current().localizedName ?? "SidecarBridge Mac"
            listener.service = NWListener.Service(name: name, type: BridgeConstants.lanServiceType)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerRestartWorkItem?.cancel()
                    self.listenerRestartWorkItem = nil
                    self.notifyLocalNetwork(.granted)
                case .waiting(let error):
                    let access = self.accessState(for: error)
                    self.notifyLocalNetwork(access)
                    if case .denied = access {
                        self.listenerRestartWorkItem?.cancel()
                        self.listenerRestartWorkItem = nil
                    } else {
                        self.scheduleListenerRestart(after: 5)
                    }
                case .failed(let error):
                    let access = self.accessState(for: error)
                    self.notifyLocalNetwork(access)
                    self.notify(connected: false, value: "Same-Wi-Fi listener: \(error.localizedDescription)")
                    listener.cancel()
                    if self.listener === listener { self.listener = nil }
                    if case .denied = access { break }
                    self.scheduleListenerRestart(after: 1)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            notifyLocalNetwork(accessState(for: error))
            notify(connected: false, value: "Same-Wi-Fi listener: \(error.localizedDescription)")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        // A Mac can advertise the same listener over Ethernet, Wi-Fi, and
        // AWDL. The iPad may reach two of those addresses at nearly the same
        // instant. Replacing the first connection here made each duplicate
        // cancel the handshake that had just won. Keep the first candidate;
        // the client cancels the redundant probes after one becomes ready.
        guard connection == nil else {
            newConnection.cancel()
            return
        }
        connection = newConnection
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.receive(on: newConnection)
            case .failed(let error):
                self.clearConnection(notify: true, error: error.localizedDescription)
            case .cancelled:
                self.clearConnection(notify: true)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        armHandshakeTimeout(for: newConnection)
    }

    private func receive(on activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak activeConnection] data, _, complete, error in
            guard let self, let activeConnection, self.connection === activeConnection else { return }
            if let data { self.receiveBuffer.append(data) }
            do {
                for payload in try LANWire.takeFrames(from: &self.receiveBuffer) {
                    try self.handle(payload, from: activeConnection)
                }
            } catch {
                activeConnection.cancel()
                self.clearConnection(notify: true, error: error.localizedDescription)
                return
            }
            if let error {
                self.clearConnection(notify: true, error: error.localizedDescription)
            } else if complete {
                self.clearConnection(notify: true)
            } else {
                self.receive(on: activeConnection)
            }
        }
    }

    private func handle(_ payload: Data, from activeConnection: NWConnection) throws {
        if sessionKey == nil {
            let hello = try LANWire.decodeHandshake(payload, marker: LANWire.clientHello)
            handshakeTimeoutWorkItem?.cancel()
            handshakeTimeoutWorkItem = nil
            let identity = BridgePeerIdentity(
                deviceID: hello.deviceID ?? "",
                deviceName: hello.deviceName,
                deviceKind: hello.deviceKind ?? "iOS device"
            )
            finishHandshake(client: hello, identity: identity, connection: activeConnection)
            return
        }

        guard let sessionKey else { return }
        let packetData = try LANWire.decrypt(payload, key: sessionKey)
        switch try PacketCodec.decode(packetData) {
        case .authentication(let message):
            handleAuthentication(message, connection: activeConnection)
        case .control(let command):
            guard isConnected else { return }
            if let input = command.remoteInputEvent {
                onInput?(input)
            } else {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
        case .file(let transfer):
            guard isConnected else { return }
            DispatchQueue.main.async { self.onFilePacket?(transfer) }
        case .jpeg, .video:
            break
        }
    }

    private func finishHandshake(
        client: LANHandshake,
        identity: BridgePeerIdentity,
        connection: NWConnection
    ) {
        DispatchQueue.main.async {
            let security = MacPairingSecurity.shared
            let macID = security.macID
            let requiresCode = security.requiresPairingCode(for: identity)
            let nonce = SecureCredentialStore.randomBytes(count: 32)
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                do {
                    guard let privateKey else { return }
                    let serverPublicKey = privateKey.publicKey.rawRepresentation
                    self.sessionKey = try LANWire.sessionKey(
                        privateKey: privateKey,
                        peerPublicKey: client.publicKey,
                        clientPublicKey: client.publicKey,
                        serverPublicKey: serverPublicKey
                    )
                    self.pendingIdentity = identity
                    self.authenticationNonce = nonce
                    self.pendingClientPublicKey = client.publicKey
                    self.pendingServerPublicKey = serverPublicKey
                    let response = LANHandshake(
                        deviceName: Host.current().localizedName ?? "Mac",
                        publicKey: serverPublicKey,
                        deviceID: nil,
                        deviceKind: "Mac",
                        macID: macID,
                        authNonce: nonce,
                        requiresPairingCode: requiresCode
                    )
                    let data = try LANWire.handshake(response, marker: LANWire.serverHello)
                    connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self, let connection, self.connection === connection else { return }
                        if let error {
                            self.clearConnection(notify: true, error: error.localizedDescription)
                        } else {
                            self.armAuthenticationTimeout(for: connection)
                        }
                    })
                } catch {
                    connection.cancel()
                    self.clearConnection(notify: true, error: error.localizedDescription)
                }
            }
        }
    }

    private func handleAuthentication(_ message: PairingMessage, connection: NWConnection) {
        guard message.kind == .response,
              let proof = message.proof,
              let identity = pendingIdentity,
              let nonce = authenticationNonce,
              let clientPublicKey = pendingClientPublicKey,
              let serverPublicKey = pendingServerPublicKey else { return }
        DispatchQueue.main.async {
            let result = MacPairingSecurity.shared.verify(
                identity: identity,
                nonce: nonce,
                proof: proof,
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey
            )
            self.queue.async { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                let response = PairingMessage(
                    kind: result.accepted ? .accepted : .rejected,
                    credential: result.issuedCredential,
                    detail: result.detail
                )
                self.sendAuthentication(response, connection: connection) { error in
                    guard error == nil else {
                        if result.issuedCredential != nil {
                            DispatchQueue.main.async {
                                MacPairingSecurity.shared.revokeCredential(for: identity)
                            }
                        }
                        self.clearConnection(notify: true, error: error?.localizedDescription)
                        return
                    }
                    guard result.accepted else { return }
                    self.handshakeTimeoutWorkItem?.cancel()
                    self.handshakeTimeoutWorkItem = nil
                    self.isConnected = true
                    self.notify(connected: true, value: "LAN:\(identity.deviceName)")
                }
            }
        }
    }

    private func sendAuthentication(
        _ message: PairingMessage,
        connection: NWConnection,
        completion: @escaping (NWError?) -> Void
    ) {
        do {
            guard let sessionKey else { return }
            let packet = try PacketCodec.encode(.authentication(message))
            connection.send(
                content: try LANWire.encrypted(packet, key: sessionKey),
                completion: .contentProcessed(completion)
            )
        } catch {
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func sendPacket(_ packet: Data, isFrame: Bool) {
        queue.async { [weak self] in
            guard let self, self.isConnected, let connection = self.connection, let key = self.sessionKey else { return }
            if isFrame && self.sendingFrame { return }
            do {
                let data = try LANWire.encrypted(packet, key: key)
                if isFrame { self.sendingFrame = true }
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if isFrame { self.sendingFrame = false }
                    if let error { self.clearConnection(notify: true, error: error.localizedDescription) }
                })
            } catch {
                self.clearConnection(notify: true, error: error.localizedDescription)
            }
        }
    }

    private func enqueueVideo(_ video: PendingVideo) {
        guard isConnected else { return }
        if waitingForKeyFrame {
            guard video.isKeyFrame else { return }
            waitingForKeyFrame = false
            pendingVideo = [video]
            sendNextVideoIfPossible()
            return
        }

        if inFlightVideoSequence == nil && pendingVideo.isEmpty {
            pendingVideo.append(video)
            sendNextVideoIfPossible()
        } else if pendingVideo.count < 2 {
            pendingVideo.append(video)
        } else {
            // Never let old frames build latency. Once the small burst buffer
            // fills, discard that dependency chain and restart at a keyframe.
            pendingVideo.removeAll(keepingCapacity: true)
            waitingForKeyFrame = true
            if video.isKeyFrame {
                waitingForKeyFrame = false
                pendingVideo = [video]
            }
        }
    }

    private func sendNextVideoIfPossible() {
        guard inFlightVideoSequence == nil,
              !pendingVideo.isEmpty,
              isConnected,
              let connection,
              let key = sessionKey else { return }

        let video = pendingVideo.removeFirst()

        do {
            let data = try LANWire.encrypted(video.packet, key: key)
            sendingFrame = true
            inFlightVideoSequence = video.sequence
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.clearConnection(notify: true, error: error.localizedDescription)
                } else if self.inFlightVideoSequence == video.sequence {
                    self.inFlightVideoSequence = nil
                    self.sendingFrame = false
                    self.sendNextVideoIfPossible()
                }
            })
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.inFlightVideoSequence == video.sequence else { return }
                self.inFlightVideoSequence = nil
                self.sendingFrame = false
                self.pendingVideo.removeAll(keepingCapacity: true)
                self.waitingForKeyFrame = true
            }
        } catch {
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func clearConnection(notify shouldNotify: Bool, error: String? = nil) {
        let wasConnected = isConnected
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        connection = nil
        privateKey = nil
        sessionKey = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        sendingFrame = false
        waitingForKeyFrame = false
        inFlightVideoSequence = nil
        pendingVideo.removeAll(keepingCapacity: true)
        pendingIdentity = nil
        authenticationNonce = nil
        pendingClientPublicKey = nil
        pendingServerPublicKey = nil
        isConnected = false
        if shouldNotify && (wasConnected || error != nil) { notify(connected: false, value: error) }
    }

    private func armHandshakeTimeout(for activeConnection: NWConnection) {
        handshakeTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak activeConnection] in
            guard let self,
                  let activeConnection,
                  self.connection === activeConnection,
                  self.sessionKey == nil else { return }
            activeConnection.cancel()
            self.clearConnection(notify: true, error: "Direct handshake timed out.")
        }
        handshakeTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func armAuthenticationTimeout(for activeConnection: NWConnection) {
        handshakeTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak activeConnection] in
            guard let self,
                  let activeConnection,
                  self.connection === activeConnection,
                  !self.isConnected else { return }
            activeConnection.cancel()
            self.clearConnection(notify: true, error: "Pairing timed out. Enter the current Mac code and reconnect.")
        }
        handshakeTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 90, execute: workItem)
    }

    private func notify(connected: Bool, value: String?) {
        DispatchQueue.main.async { self.onConnectionChanged?(connected, value) }
    }

    private func notifyLocalNetwork(_ state: LocalNetworkAccessState) {
        DispatchQueue.main.async { self.onLocalNetworkStateChanged?(state) }
    }

    private func scheduleListenerRestart(after delay: TimeInterval) {
        listenerRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.startListener()
        }
        listenerRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
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
