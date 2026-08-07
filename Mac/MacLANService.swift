import AppKit
import CryptoKit
import Foundation
import Network

final class MacLANService {
    var onCommand: ((ControlMessage) -> Void)?
    var onInput: ((RemoteInputEvent) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onKeyFrameNeeded: (() -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?
    var onListenerStateChanged: ((Bool, String) -> Void)?

    private let queue = DispatchQueue(
        label: "SidecarBridge.MacLAN",
        qos: .userInteractive
    )
    private var listener: NWListener?
    private var listenerRestartWorkItem: DispatchWorkItem?
    private var connection: NWConnection?
    private var secureSession: SecurePacketSession?
    private final class Candidate {
        let connection: NWConnection
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let remoteHostKey: String
        var secureSession: SecurePacketSession?
        var pendingIdentity: BridgePeerIdentity?
        var authenticationNonce: Data?
        var clientPublicKey: Data?
        var serverPublicKey: Data?
        var receiveBuffer = Data()
        var timeoutWorkItem: DispatchWorkItem?
        var isAuthenticated = false

        init(connection: NWConnection, remoteHostKey: String) {
            self.connection = connection
            self.remoteHostKey = remoteHostKey
        }
    }
    private var candidates: [ObjectIdentifier: Candidate] = [:]
    private let maximumPendingCandidates = 8
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
            self?.listener?.cancel()
            self?.listener = nil
            self?.notifyListener(
                ready: false,
                detail: "Encrypted local listener stopped."
            )
            self?.cancelAllCandidates()
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
            var txtRecord = NWTXTRecord()
            txtRecord[BridgeConstants.protocolTXTKey] = String(LANWire.securityProtocolVersion)
            txtRecord[BridgeConstants.buildTXTKey] = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
            listener.service = NWListener.Service(
                name: name,
                type: BridgeConstants.lanServiceType,
                txtRecord: txtRecord
            )
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerRestartWorkItem?.cancel()
                    self.listenerRestartWorkItem = nil
                    self.notifyLocalNetwork(.granted)
                    self.notifyListener(
                        ready: true,
                        detail: "Listening for the selected iPad or iPhone on TCP 45454 via _sb-direct._tcp."
                    )
                case .waiting(let error):
                    let access = self.accessState(for: error)
                    self.notifyLocalNetwork(access)
                    self.notifyListener(
                        ready: false,
                        detail: "Incoming local listener is waiting: \(error.localizedDescription)"
                    )
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
                    self.notifyListener(
                        ready: false,
                        detail: "Incoming local listener failed: \(error.localizedDescription)"
                    )
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
            notifyListener(
                ready: false,
                detail: "Incoming local listener could not start: \(error.localizedDescription)"
            )
        }
    }

    private func accept(_ newConnection: NWConnection) {
        guard !isConnected,
              candidates.count < maximumPendingCandidates else {
            newConnection.cancel()
            return
        }

        let hostKey = Self.remoteHostKey(for: newConnection.endpoint)
        guard !candidates.values.contains(where: {
            !$0.isAuthenticated && $0.remoteHostKey == hostKey
        }) else {
            newConnection.cancel()
            return
        }

        let candidate = Candidate(connection: newConnection, remoteHostKey: hostKey)
        candidates[ObjectIdentifier(newConnection)] = candidate
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self,
                  let newConnection,
                  let candidate = self.candidates[ObjectIdentifier(newConnection)] else { return }
            switch state {
            case .ready:
                self.receive(on: candidate)
            case .failed(let error):
                self.clear(candidate, error: error.localizedDescription)
            case .cancelled:
                self.clear(candidate)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        armHandshakeTimeout(for: candidate)
    }

    private func receive(on candidate: Candidate) {
        let activeConnection = candidate.connection
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak activeConnection] data, _, complete, error in
            guard let self,
                  let activeConnection,
                  self.candidates[ObjectIdentifier(activeConnection)] === candidate else { return }
            if let data { candidate.receiveBuffer.append(data) }
            do {
                for payload in try LANWire.takeFrames(from: &candidate.receiveBuffer) {
                    try self.handle(payload, from: candidate)
                }
            } catch {
                activeConnection.cancel()
                self.clear(candidate, error: error.localizedDescription)
                return
            }
            if let error {
                self.clear(candidate, error: error.localizedDescription)
            } else if complete {
                self.clear(candidate)
            } else {
                self.receive(on: candidate)
            }
        }
    }

    private func handle(_ payload: Data, from candidate: Candidate) throws {
        if candidate.secureSession == nil {
            let hello = try LANWire.decodeHandshake(payload, marker: LANWire.clientHello)
            candidate.timeoutWorkItem?.cancel()
            candidate.timeoutWorkItem = nil
            let identity = BridgePeerIdentity(
                deviceID: hello.deviceID ?? "",
                deviceName: hello.deviceName,
                deviceKind: hello.deviceKind ?? "iOS device"
            )
            guard !identity.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LANWire.LANError.authenticationFailed
            }
            finishHandshake(client: hello, identity: identity, candidate: candidate)
            return
        }

        guard let secureSession = candidate.secureSession else { return }
        let packetData = try LANWire.decrypt(payload, session: secureSession)
        switch try PacketCodec.decode(packetData) {
        case .authentication(let message):
            handleAuthentication(message, candidate: candidate)
        case .control(let command):
            guard candidate.isAuthenticated,
                  connection === candidate.connection else { return }
            if let input = command.remoteInputEvent {
                onInput?(input)
            } else {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
        case .file(let transfer):
            guard candidate.isAuthenticated,
                  connection === candidate.connection else { return }
            DispatchQueue.main.async { self.onFilePacket?(transfer) }
        case .jpeg, .video:
            break
        }
    }

    private func finishHandshake(
        client: LANHandshake,
        identity: BridgePeerIdentity,
        candidate: Candidate
    ) {
        DispatchQueue.main.async {
            let security = MacPairingSecurity.shared
            let macID = security.macID
            let requiresCode = security.requiresPairingCode(for: identity)
            let nonce = SecureCredentialStore.randomBytes(count: 32)
            self.queue.async { [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidates[ObjectIdentifier(candidate.connection)] === candidate else { return }
                do {
                    let privateKey = candidate.privateKey
                    let serverPublicKey = privateKey.publicKey.rawRepresentation
                    candidate.secureSession = try LANWire.secureSession(
                        privateKey: privateKey,
                        peerPublicKey: client.publicKey,
                        clientPublicKey: client.publicKey,
                        serverPublicKey: serverPublicKey,
                        role: .server
                    )
                    candidate.pendingIdentity = identity
                    candidate.authenticationNonce = nonce
                    candidate.clientPublicKey = client.publicKey
                    candidate.serverPublicKey = serverPublicKey
                    let response = LANHandshake(
                        protocolVersion: LANWire.securityProtocolVersion,
                        deviceName: Host.current().localizedName ?? "Mac",
                        publicKey: serverPublicKey,
                        deviceID: nil,
                        deviceKind: "Mac",
                        macID: macID,
                        authNonce: nonce,
                        requiresPairingCode: requiresCode
                    )
                    let data = try LANWire.handshake(response, marker: LANWire.serverHello)
                    candidate.connection.send(content: data, completion: .contentProcessed { [weak self, weak candidate] error in
                        guard let self,
                              let candidate,
                              self.candidates[ObjectIdentifier(candidate.connection)] === candidate else { return }
                        if let error {
                            self.clear(candidate, error: error.localizedDescription)
                        } else {
                            self.armAuthenticationTimeout(for: candidate)
                        }
                    })
                } catch {
                    candidate.connection.cancel()
                    self.clear(candidate, error: error.localizedDescription)
                }
            }
        }
    }

    private func handleAuthentication(_ message: PairingMessage, candidate: Candidate) {
        guard message.kind == .response,
              message.protocolVersion == LANWire.securityProtocolVersion,
              let proof = message.proof,
              let identity = candidate.pendingIdentity,
              message.identity == identity,
              let nonce = candidate.authenticationNonce,
              let clientPublicKey = candidate.clientPublicKey,
              let serverPublicKey = candidate.serverPublicKey else { return }
        DispatchQueue.main.async {
            let result = MacPairingSecurity.shared.verify(
                identity: identity,
                nonce: nonce,
                proof: proof,
                channelBinding: PairingProof.lanChannelBinding(
                    clientPublicKey: clientPublicKey,
                    serverPublicKey: serverPublicKey
                )
            )
            self.queue.async { [weak self, weak candidate] in
                guard let self,
                      let candidate,
                      self.candidates[ObjectIdentifier(candidate.connection)] === candidate else { return }
                let response = PairingMessage(
                    kind: result.accepted ? .accepted : .rejected,
                    protocolVersion: LANWire.securityProtocolVersion,
                    proof: result.responseProof,
                    credential: result.issuedCredential,
                    detail: result.detail
                )
                self.sendAuthentication(response, candidate: candidate) { error in
                    guard error == nil else {
                        if result.issuedCredential != nil {
                            DispatchQueue.main.async {
                                MacPairingSecurity.shared.revokeCredential(for: identity)
                            }
                        }
                        self.clear(candidate, error: error?.localizedDescription)
                        return
                    }
                    guard result.accepted else { return }
                    candidate.timeoutWorkItem?.cancel()
                    candidate.timeoutWorkItem = nil
                    self.cancelAllCandidates(except: candidate)
                    candidate.isAuthenticated = true
                    self.connection = candidate.connection
                    self.secureSession = candidate.secureSession
                    self.isConnected = true
                    self.notify(connected: true, value: "LAN:\(identity.deviceName)")
                }
            }
        }
    }

    private func sendAuthentication(
        _ message: PairingMessage,
        candidate: Candidate,
        completion: @escaping (NWError?) -> Void
    ) {
        do {
            guard let secureSession = candidate.secureSession else { return }
            let packet = try PacketCodec.encode(.authentication(message))
            candidate.connection.send(
                content: try LANWire.encrypted(packet, session: secureSession),
                completion: .contentProcessed(completion)
            )
        } catch {
            clear(candidate, error: error.localizedDescription)
        }
    }

    private func sendPacket(_ packet: Data, isFrame: Bool) {
        queue.async { [weak self] in
            guard let self,
                  self.isConnected,
                  let connection = self.connection,
                  let secureSession = self.secureSession else { return }
            if isFrame && self.sendingFrame { return }
            do {
                let data = try LANWire.encrypted(packet, session: secureSession)
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
            onKeyFrameNeeded?()
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
              let secureSession else { return }

        let video = pendingVideo.removeFirst()

        do {
            let data = try LANWire.encrypted(video.packet, session: secureSession)
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
                self.onKeyFrameNeeded?()
            }
        } catch {
            clearConnection(notify: true, error: error.localizedDescription)
        }
    }

    private func clearConnection(notify shouldNotify: Bool, error: String? = nil) {
        let wasConnected = isConnected
        if let connection,
           let candidate = candidates[ObjectIdentifier(connection)] {
            candidate.timeoutWorkItem?.cancel()
            candidates.removeValue(forKey: ObjectIdentifier(connection))
        }
        connection = nil
        secureSession = nil
        sendingFrame = false
        waitingForKeyFrame = false
        inFlightVideoSequence = nil
        pendingVideo.removeAll(keepingCapacity: true)
        isConnected = false
        if shouldNotify && (wasConnected || error != nil) { notify(connected: false, value: error) }
    }

    private func clear(_ candidate: Candidate, error: String? = nil) {
        let identifier = ObjectIdentifier(candidate.connection)
        guard candidates[identifier] === candidate else { return }
        candidate.timeoutWorkItem?.cancel()
        candidate.timeoutWorkItem = nil
        candidates.removeValue(forKey: identifier)
        if connection === candidate.connection {
            clearConnection(notify: true, error: error)
        }
    }

    private func cancelAllCandidates(except retained: Candidate? = nil) {
        for candidate in Array(candidates.values) where candidate !== retained {
            candidate.timeoutWorkItem?.cancel()
            candidate.connection.cancel()
            candidates.removeValue(forKey: ObjectIdentifier(candidate.connection))
        }
    }

    private func armHandshakeTimeout(for candidate: Candidate) {
        candidate.timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak candidate] in
            guard let self,
                  let candidate,
                  self.candidates[ObjectIdentifier(candidate.connection)] === candidate,
                  candidate.secureSession == nil else { return }
            candidate.connection.cancel()
            self.clear(candidate, error: "Direct handshake timed out.")
        }
        candidate.timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func armAuthenticationTimeout(for candidate: Candidate) {
        candidate.timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak candidate] in
            guard let self,
                  let candidate,
                  self.candidates[ObjectIdentifier(candidate.connection)] === candidate,
                  !candidate.isAuthenticated else { return }
            candidate.connection.cancel()
            self.clear(candidate, error: "Pairing timed out. Enter the current Mac code and reconnect.")
        }
        candidate.timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 60, execute: workItem)
    }

    private static func remoteHostKey(for endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return String(describing: host)
        }
        return String(describing: endpoint)
    }

    private func notify(connected: Bool, value: String?) {
        DispatchQueue.main.async { self.onConnectionChanged?(connected, value) }
    }

    private func notifyLocalNetwork(_ state: LocalNetworkAccessState) {
        DispatchQueue.main.async { self.onLocalNetworkStateChanged?(state) }
    }

    private func notifyListener(ready: Bool, detail: String) {
        DispatchQueue.main.async { self.onListenerStateChanged?(ready, detail) }
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
