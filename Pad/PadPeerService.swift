import Foundation
import MultipeerConnectivity
import UIKit

final class PadPeerService: NSObject {
    var onFrame: ((Data) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onCommand: ((ControlMessage) -> Void)?
    var onFilePacket: ((FileTransferPacket) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?
    var onConnectionHealthChanged: ((String, Int?) -> Void)?

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser?
    private var invitedPeers = Set<String>()
    private let lan = PadLANService()
    private var mcConnected = false
    private var lanConnected = false
    private var mcPeerName: String?
    private var lanPeerName: String?
    private var started = false
    private var browserRunning = false
    private var fallbackWorkItem: DispatchWorkItem?
    private var mcConnectionWatchdog: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSentAt: [String: TimeInterval] = [:]
    private var lastPeerActivity = ProcessInfo.processInfo.systemUptime
    private var validationWorkItem: DispatchWorkItem?
    private var peerSupportsHeartbeat = false
    private var pendingMultipeerInput = RemoteInputCoalescer()
    private var multipeerInputDrainScheduled = false

    override init() {
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        super.init()
        session.delegate = self
        lan.onFrame = { [weak self] frame in
            self?.notePeerActivity()
            self?.onFrame?(frame)
        }
        lan.onVideoFrame = { [weak self] frame in
            self?.notePeerActivity()
            self?.onVideoFrame?(frame)
        }
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
                self.pendingMultipeerInput.removeAll()
                self.multipeerInputDrainScheduled = false
                self.lanPeerName = value
                self.fallbackWorkItem?.cancel()
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

    func restart() {
        started = true
        fallbackWorkItem?.cancel()
        stopMultipeerFallback()
        invitedPeers.removeAll()
        lan.restart()
        scheduleMultipeerFallback()
    }

    func resumeAfterBackground() {
        guard lanConnected || mcConnected else {
            onConnectionHealthChanged?("Recovering discovery", nil)
            restart()
            return
        }
        onConnectionHealthChanged?("Verifying after background", nil)
        let token = sendHeartbeatPing()
        let sentAt = heartbeatSentAt[token] ?? ProcessInfo.processInfo.systemUptime
        validationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.heartbeatSentAt[token] != nil else { return }
            self.heartbeatSentAt.removeValue(forKey: token)
            if self.peerSupportsHeartbeat, self.lastPeerActivity <= sentAt {
                self.recoverStaleConnection(reason: "No encrypted traffic after returning from background.")
            } else if !self.peerSupportsHeartbeat {
                self.onConnectionHealthChanged?("Connected — update Mac app for health checks", nil)
            } else {
                self.onConnectionHealthChanged?("Encrypted link healthy", nil)
            }
        }
        validationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    func send(_ message: ControlMessage) {
        if lanConnected {
            lan.send(message)
        } else if !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.control(message)) {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    func sendInput(_ input: RemoteInputEvent) {
        if lanConnected {
            lan.sendInput(input)
            return
        }
        guard !session.connectedPeers.isEmpty else { return }

        pendingMultipeerInput.enqueue(input)
        if input.isCoalescibleInput {
            scheduleMultipeerInputDrain()
        } else {
            drainMultipeerInput()
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

    private func reportConnection(error: String? = nil) {
        if lanConnected {
            onConnectionChanged?(true, lanPeerName)
        } else if mcConnected {
            onConnectionChanged?(true, mcPeerName)
        } else {
            onConnectionChanged?(false, error)
        }
    }

    private func scheduleMultipeerInputDrain() {
        guard !multipeerInputDrainScheduled else { return }
        multipeerInputDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainMultipeerInput()
        }
    }

    private func drainMultipeerInput() {
        multipeerInputDrainScheduled = false
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            pendingMultipeerInput.removeAll()
            return
        }

        while let input = pendingMultipeerInput.popFirst() {
            guard let message = ControlMessage.input(input),
                  let data = try? PacketCodec.encode(.control(message)) else { continue }
            let mode: MCSessionSendDataMode = input.isCoalescibleInput ? .unreliable : .reliable
            try? session.send(data, toPeers: peers, with: mode)
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
            validationWorkItem?.cancel()
            validationWorkItem = nil
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
        timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.heartbeatTick() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        validationWorkItem?.cancel()
        validationWorkItem = nil
        heartbeatSentAt.removeAll(keepingCapacity: true)
        peerSupportsHeartbeat = false
    }

    private func heartbeatTick() {
        guard lanConnected || mcConnected else {
            stopHeartbeat()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if peerSupportsHeartbeat, now - lastPeerActivity > 9 {
            recoverStaleConnection(reason: "Encrypted link stopped responding.")
            return
        }
        _ = sendHeartbeatPing()
        heartbeatSentAt = heartbeatSentAt.filter { now - $0.value < 16 }
    }

    @discardableResult
    private func sendHeartbeatPing() -> String {
        let token = UUID().uuidString
        heartbeatSentAt[token] = ProcessInfo.processInfo.systemUptime
        send(ControlMessage(.status, detail: "heartbeat-ping:\(token)"))
        return token
    }

    private func notePeerActivity() {
        lastPeerActivity = ProcessInfo.processInfo.systemUptime
    }

    private func recoverStaleConnection(reason: String) {
        onConnectionHealthChanged?("Recovering stale connection", nil)
        stopHeartbeat()
        if lanConnected {
            lan.forceReconnect(reason: reason)
        } else {
            session.disconnect()
            mcConnected = false
            mcPeerName = nil
            restartMultipeerBrowserAfterDisconnect()
            reportConnection(error: reason)
        }
    }

    private func scheduleMultipeerFallback() {
        guard started, !lanConnected, !browserRunning else { return }
        fallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, !self.lanConnected, !self.browserRunning else { return }
            let browser = MCNearbyServiceBrowser(
                peer: self.peerID,
                serviceType: BridgeConstants.serviceType
            )
            browser.delegate = self
            self.browser = browser
            self.browserRunning = true
            print("[SidecarBridge/P2P] Starting nearby fallback browser")
            browser.startBrowsingForPeers()
        }
        fallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func stopMultipeerFallback() {
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        mcConnectionWatchdog?.cancel()
        mcConnectionWatchdog = nil
        if browserRunning {
            browser?.stopBrowsingForPeers()
            browserRunning = false
        }
        browser?.delegate = nil
        browser = nil
        // A peer in MCSessionState.connecting is not included in
        // connectedPeers. Always disconnect so a stalled invitation cannot be
        // reused by the next discovery attempt.
        session.disconnect()
        rebuildMultipeerSession()
        mcConnected = false
        mcPeerName = nil
        invitedPeers.removeAll()
    }

    private func armMultipeerConnectionWatchdog(for peerName: String) {
        mcConnectionWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.lanConnected, !self.mcConnected else { return }
            print("[SidecarBridge/P2P] Handshake timed out; resetting session")
            self.session.disconnect()
            self.rebuildMultipeerSession()
            self.invitedPeers.remove(peerName)
            if self.browserRunning {
                self.browser?.stopBrowsingForPeers()
                self.browserRunning = false
            }
            self.browser?.delegate = nil
            self.browser = nil
            self.onConnectionChanged?(false, "Nearby P2P handshake timed out; retrying automatically.")
            self.scheduleMultipeerFallback()
        }
        mcConnectionWatchdog = workItem
        // AWDL/Bluetooth discovery can take several seconds after iOS resumes
        // the app. Do not tear down a valid invitation while it is completing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func rebuildMultipeerSession() {
        session.delegate = nil
        session.disconnect()
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
    }

    private func restartMultipeerBrowserAfterDisconnect() {
        guard started, !lanConnected else { return }
        if browserRunning {
            browser?.stopBrowsingForPeers()
            browserRunning = false
        }
        browser?.delegate = nil
        browser = nil
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        scheduleMultipeerFallback()
    }
}

extension PadPeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let self, let browser,
                  self.browser === browser,
                  !self.invitedPeers.contains(peerID.displayName),
                  self.session.connectedPeers.isEmpty else { return }
            print("[SidecarBridge/P2P] Found and inviting \(peerID.displayName)")
            self.invitedPeers.insert(peerID.displayName)
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
            self.armMultipeerConnectionWatchdog(for: peerID.displayName)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.invitedPeers.remove(peerID.displayName)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            guard self.browser === browser else { return }
            browser.delegate = nil
            self.browser = nil
            self.browserRunning = false
            self.onConnectionChanged?(false, error.localizedDescription)
            self.scheduleMultipeerFallback()
        }
    }
}

extension PadPeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard session === self.session else { return }
            print("[SidecarBridge/P2P] Session with \(peerID.displayName): \(state.rawValue)")
            self.mcConnected = !session.connectedPeers.isEmpty
            self.mcPeerName = self.mcConnected ? (session.connectedPeers.first?.displayName ?? peerID.displayName) : nil
            if state == .connected {
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
            } else if state == .connecting {
                self.armMultipeerConnectionWatchdog(for: peerID.displayName)
            } else {
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
                self.pendingMultipeerInput.removeAll()
                self.multipeerInputDrainScheduled = false
                self.invitedPeers.remove(peerID.displayName)
                self.restartMultipeerBrowserAfterDisconnect()
            }
            self.reportConnection()
            self.updateHeartbeatState()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? PacketCodec.decode(data) else { return }
        switch packet {
        case .control(let command):
            DispatchQueue.main.async { self.route(command) }
        case .jpeg(let frame):
            DispatchQueue.main.async {
                self.notePeerActivity()
                self.onFrame?(frame)
            }
        case .video(let frame):
            DispatchQueue.main.async {
                self.notePeerActivity()
                self.onVideoFrame?(frame)
            }
        case .file(let transfer):
            DispatchQueue.main.async {
                self.notePeerActivity()
                self.onFilePacket?(transfer)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
