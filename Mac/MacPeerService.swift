import AppKit
import Foundation
import MultipeerConnectivity

enum MacP2PState: Equatable {
    case starting
    case advertising
    case connecting(String)
    case connected(String)
    case recovering(String)
    case standbyDirect
}

final class MacPeerService: NSObject {
    private struct PendingMCVideo {
        let sequence: UInt64
        let isKeyFrame: Bool
        let data: Data
    }

    var onCommand: ((ControlMessage) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?
    var onP2PStateChanged: ((MacP2PState) -> Void)?
    var onConnectionHealthChanged: ((String, Int?) -> Void)?

    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private var advertiser: MCNearbyServiceAdvertiser?
    private let lan = MacLANService()
    private var mcConnected = false
    private var lanConnected = false
    private var mcPeerName: String?
    private var lanPeerName: String?
    private var started = false
    private var advertiserRunning = false
    private var fallbackWorkItem: DispatchWorkItem?
    private var mcConnectionWatchdog: DispatchWorkItem?
    private let mcVideoQueue = DispatchQueue(label: "SidecarBridge.MCVideo")
    private var mcVideoInFlight: UInt64?
    private var pendingMCVideo: [PendingMCVideo] = []
    private var mcWaitingForKeyFrame = false
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSentAt: [String: TimeInterval] = [:]
    private var lastPeerActivity = ProcessInfo.processInfo.systemUptime
    private var peerSupportsHeartbeat = false

    override init() {
        super.init()
        session.delegate = self
        lan.onCommand = { [weak self] command in self?.route(command) }
        lan.onFilePacket = { [weak self] transfer in
            self?.notePeerActivity()
            self?.onFilePacket?(transfer)
        }
        lan.onLocalNetworkStateChanged = { [weak self] state in
            self?.onLocalNetworkStateChanged?(state)
        }
        lan.onConnectionChanged = { [weak self] connected, value in
            guard let self else { return }
            self.lanConnected = connected
            if connected {
                self.lanPeerName = value
                self.fallbackWorkItem?.cancel()
                self.onP2PStateChanged?(.standbyDirect)
                self.stopMultipeerFallback()
            } else {
                self.lanPeerName = nil
                self.scheduleMultipeerFallback()
            }
            self.reportConnection(error: connected ? nil : value)
            self.updateHeartbeatState()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        lan.start()
        scheduleMultipeerFallback()
    }

    func stop() {
        started = false
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        stopMultipeerFallback()
        stopHeartbeat()
        lan.stop()
    }

    var hasConnectedPeer: Bool { lanConnected || mcConnected }

    func send(_ message: ControlMessage) {
        if lanConnected {
            lan.send(message)
        } else if !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.control(message)) {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    func sendFrame(_ jpeg: Data) {
        if lanConnected {
            lan.sendFrame(jpeg)
        } else if !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.jpeg(jpeg)) {
            try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
        }
    }

    func sendFilePacket(_ transfer: FileTransferPacket) {
        if lanConnected {
            lan.sendFilePacket(transfer)
        } else if !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.file(transfer)) {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    func sendVideoFrame(_ frame: VideoFrame) {
        if lanConnected {
            lan.sendVideoFrame(frame)
        } else if !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.video(frame)) {
            mcVideoQueue.async { [weak self] in
                self?.enqueueMCVideo(PendingMCVideo(
                    sequence: frame.sequence,
                    isKeyFrame: frame.isKeyFrame,
                    data: data
                ))
            }
        }
    }

    func acknowledgeVideo(sequence: UInt64) {
        if lanConnected {
            lan.acknowledgeVideo(sequence: sequence)
        } else {
            mcVideoQueue.async { [weak self] in
                guard let self, self.mcVideoInFlight == sequence else { return }
                self.mcVideoInFlight = nil
                self.sendNextMCVideoIfPossible()
            }
        }
    }

    private func enqueueMCVideo(_ video: PendingMCVideo) {
        guard !session.connectedPeers.isEmpty else { return }
        if mcWaitingForKeyFrame {
            guard video.isKeyFrame else { return }
            mcWaitingForKeyFrame = false
            pendingMCVideo = [video]
            sendNextMCVideoIfPossible()
            return
        }

        if mcVideoInFlight == nil && pendingMCVideo.isEmpty {
            pendingMCVideo.append(video)
            sendNextMCVideoIfPossible()
        } else if pendingMCVideo.count < 3 {
            pendingMCVideo.append(video)
        } else {
            pendingMCVideo.removeAll(keepingCapacity: true)
            mcWaitingForKeyFrame = true
            if video.isKeyFrame {
                mcWaitingForKeyFrame = false
                pendingMCVideo = [video]
            }
        }
    }

    private func sendNextMCVideoIfPossible() {
        guard mcVideoInFlight == nil,
              !pendingMCVideo.isEmpty,
              !session.connectedPeers.isEmpty else { return }
        let video = pendingMCVideo.removeFirst()
        do {
            try session.send(video.data, toPeers: session.connectedPeers, with: .reliable)
            mcVideoInFlight = video.sequence
            // Multipeer can take longer than direct TCP to deliver a large
            // keyframe. A one-second timeout repeatedly abandoned valid
            // transfers and caused a keyframe/congestion loop.
            mcVideoQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.mcVideoInFlight == video.sequence else { return }
                self.mcVideoInFlight = nil
                self.pendingMCVideo.removeAll(keepingCapacity: true)
                self.mcWaitingForKeyFrame = true
            }
        } catch {
            mcVideoInFlight = nil
            pendingMCVideo.removeAll(keepingCapacity: true)
            mcWaitingForKeyFrame = true
        }
    }

    private func resetMCVideoQueue() {
        mcVideoQueue.async { [weak self] in
            self?.mcVideoInFlight = nil
            self?.pendingMCVideo.removeAll(keepingCapacity: true)
            self?.mcWaitingForKeyFrame = false
        }
    }

    private func reportConnection(error: String? = nil) {
        if lanConnected {
            onConnectionChanged?(true, lanPeerName)
        } else if mcConnected {
            onConnectionChanged?(true, mcPeerName)
        } else {
            onConnectionChanged?(false, error)
        }
    }

    private func route(_ command: ControlMessage) {
        notePeerActivity()
        guard command.kind == .status,
              let detail = command.detail,
              detail.hasPrefix("heartbeat-") else {
            onCommand?(command)
            return
        }
        if detail.hasPrefix("heartbeat-ping:") {
            peerSupportsHeartbeat = true
            let token = String(detail.dropFirst("heartbeat-ping:".count))
            send(ControlMessage(.status, detail: "heartbeat-pong:\(token)"))
        } else if detail.hasPrefix("heartbeat-pong:") {
            let token = String(detail.dropFirst("heartbeat-pong:".count))
            guard let sentAt = heartbeatSentAt.removeValue(forKey: token) else { return }
            peerSupportsHeartbeat = true
            let latency = max(0, Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1_000))
            onConnectionHealthChanged?("Encrypted link healthy", latency)
        }
    }

    private func updateHeartbeatState() {
        if lanConnected || mcConnected {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        lastPeerActivity = ProcessInfo.processInfo.systemUptime
        peerSupportsHeartbeat = false
        onConnectionHealthChanged?("Verifying encrypted link", nil)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 4, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        heartbeatSentAt.removeAll(keepingCapacity: true)
        peerSupportsHeartbeat = false
    }

    private func heartbeatTick() {
        guard lanConnected || mcConnected else {
            stopHeartbeat()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if peerSupportsHeartbeat, now - lastPeerActivity > 12 {
            recoverStaleConnection(reason: "Encrypted link stopped responding.")
            return
        }
        let token = UUID().uuidString
        heartbeatSentAt[token] = now
        send(ControlMessage(.status, detail: "heartbeat-ping:\(token)"))
        heartbeatSentAt = heartbeatSentAt.filter { now - $0.value < 16 }
    }

    private func notePeerActivity() {
        lastPeerActivity = ProcessInfo.processInfo.systemUptime
    }

    private func recoverStaleConnection(reason: String) {
        onConnectionHealthChanged?("Recovering stale connection", nil)
        onP2PStateChanged?(.recovering(reason))
        stopHeartbeat()
        if lanConnected {
            lan.forceDisconnect(reason: reason)
        } else {
            session.disconnect()
            mcConnected = false
            mcPeerName = nil
            resetMCVideoQueue()
            restartMultipeerAdvertisingAfterDisconnect()
            reportConnection(error: reason)
        }
    }

    private func scheduleMultipeerFallback() {
        guard started, !lanConnected, !advertiserRunning else { return }
        onP2PStateChanged?(.starting)
        fallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.lanConnected, !self.advertiserRunning else { return }
            let advertiser = MCNearbyServiceAdvertiser(
                peer: self.peerID,
                discoveryInfo: ["role": "mac"],
                serviceType: BridgeConstants.serviceType
            )
            advertiser.delegate = self
            self.advertiser = advertiser
            self.advertiserRunning = true
            advertiser.startAdvertisingPeer()
            self.onP2PStateChanged?(.advertising)
        }
        fallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func stopMultipeerFallback() {
        resetMCVideoQueue()
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        mcConnectionWatchdog?.cancel()
        mcConnectionWatchdog = nil
        if advertiserRunning {
            advertiser?.stopAdvertisingPeer()
            advertiserRunning = false
        }
        advertiser?.delegate = nil
        advertiser = nil
        session.disconnect()
        mcConnected = false
        mcPeerName = nil
    }

    private func armMultipeerConnectionWatchdog() {
        mcConnectionWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.lanConnected, !self.mcConnected else { return }
            self.session.disconnect()
            if self.advertiserRunning {
                self.advertiser?.stopAdvertisingPeer()
                self.advertiserRunning = false
            }
            self.advertiser?.delegate = nil
            self.advertiser = nil
            let message = "Nearby P2P handshake timed out; advertising again."
            self.onP2PStateChanged?(.recovering(message))
            self.onConnectionChanged?(false, message)
            self.scheduleMultipeerFallback()
        }
        mcConnectionWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    private func restartMultipeerAdvertisingAfterDisconnect() {
        guard started, !lanConnected else { return }
        if advertiserRunning {
            advertiser?.stopAdvertisingPeer()
            advertiserRunning = false
        }
        advertiser?.delegate = nil
        advertiser = nil
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        scheduleMultipeerFallback()
    }
}

extension MacPeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        onP2PStateChanged?(.connecting(peerID.displayName))
        let paired = UserDefaults.standard.string(forKey: "pairedPeerName")
        if paired == peerID.displayName {
            invitationHandler(true, session)
            return
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Pair with \(peerID.displayName)?"
            alert.informativeText = "Allow this iPad to request Sidecar, receive your Mac screen, send input, and exchange files you choose."
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Cancel")
            let accepted = alert.runModal() == .alertFirstButtonReturn
            if accepted {
                UserDefaults.standard.set(peerID.displayName, forKey: "pairedPeerName")
            }
            invitationHandler(accepted, accepted ? self.session : nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            guard self.advertiser === advertiser else { return }
            advertiser.delegate = nil
            self.advertiser = nil
            self.advertiserRunning = false
            self.onP2PStateChanged?(.recovering(error.localizedDescription))
            self.onConnectionChanged?(false, error.localizedDescription)
            self.scheduleMultipeerFallback()
        }
    }
}

extension MacPeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.mcConnected = !session.connectedPeers.isEmpty
            self.mcPeerName = self.mcConnected ? (session.connectedPeers.first?.displayName ?? peerID.displayName) : nil
            if state == .connected {
                self.onP2PStateChanged?(.connected(peerID.displayName))
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
            } else if state == .connecting {
                self.onP2PStateChanged?(.connecting(peerID.displayName))
                self.armMultipeerConnectionWatchdog()
            } else {
                self.onP2PStateChanged?(
                    self.lanConnected
                        ? .standbyDirect
                        : .recovering("Connection ended; advertising again.")
                )
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
                self.restartMultipeerAdvertisingAfterDisconnect()
            }
            self.reportConnection()
            if state != .connected { self.resetMCVideoQueue() }
            self.updateHeartbeatState()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? PacketCodec.decode(data) else { return }
        switch packet {
        case .control(let command):
            DispatchQueue.main.async { self.route(command) }
        case .file(let transfer):
            DispatchQueue.main.async {
                self.notePeerActivity()
                self.onFilePacket?(transfer)
            }
        case .jpeg, .video:
            break
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
