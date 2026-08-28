import CryptoKit
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
    var onPairingCodeRequired: ((String, String?) -> Void)?
    var onDiscoveredMacsChanged: (([String]) -> Void)?

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser?
    private var invitedPeers = Set<String>()
    private let lan = PadLANService()
    private var mcConnected = false
    private var lanConnected = false
    private var mcPeerName: String?
    private var pendingMCPeer: MCPeerID?
    private var pendingMCMacID: String?
    private var pendingMCNonce: Data?
    private var pendingMCChannelBinding: Data?
    private var pendingMCSecret: Data?
    private var pendingMCPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var mcSecureSession: SecurePacketSession?
    private var submittedMCPairingCode: String?
    private var usedSavedMCCredential = false
    private var lanPeerName: String?
    private var started = false
    private var browserRunning = false
    private var fallbackWorkItem: DispatchWorkItem?
    private var mcConnectionWatchdog: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSentAt: [String: TimeInterval] = [:]
    private let activityLock = NSLock()
    private var lastPeerActivity = ProcessInfo.processInfo.systemUptime
    private var validationWorkItem: DispatchWorkItem?
    private var peerSupportsHeartbeat = false
    private var applicationIsBackgrounded = false
    // Wi-Fi/AWDL can take several seconds to deliver the first packet after
    // iPadOS resumes the app. Keep the session in a coordinated grace window
    // instead of letting the idle watchdog tear down a route that is waking.
    private var resumeGraceUntil: TimeInterval = 0
    private var pendingMultipeerInput = RemoteInputCoalescer()
    private var multipeerInputDrainScheduled = false
    private var lanDiscoveredMacs = Set<String>()
    private var multipeerDiscoveredMacs: [String: MCPeerID] = [:]
    private var multipeerDiscoveredHosts: [String: [String]] = [:]
    private var selectedMacName: String?
    // Finding a peer is not consent to invite it. This is enabled only by the
    // explicit Connect action in PadConnectionModel.
    private var userRequestedConnection = false

    // Video callbacks arrive on the LAN/Multipeer queues while the display
    // layer is main-thread bound. JPEG fallback frames are independent and
    // can safely be coalesced, but H.264 P-frames must stay ordered: dropping
    // an arbitrary P-frame breaks the decoder dependency chain and causes a
    // visible flash until the next IDR. Keep a small ordered H.264 window and
    // schedule one main-actor drain.
    private enum PendingVideoDelivery {
        case jpeg(Data)
        case h264(VideoFrame)
    }
    private let videoDeliveryLock = NSLock()
    private var pendingVideoDeliveries: [PendingVideoDelivery] = []
    // Avoid shifting every retained frame with removeFirst(). The queue is
    // bounded, but at 60/120 FPS that copy still runs on every delivery burst.
    private var pendingVideoDeliveryHead = 0
    private var waitingForH264KeyFrame = false
    private var videoDeliveryScheduled = false
    private var videoDeliveryGeneration: UInt64 = 0

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
            self?.enqueueVideoDelivery(.jpeg(frame))
        }
        lan.onVideoFrame = { [weak self] frame in
            self?.notePeerActivity()
            self?.enqueueVideoDelivery(.h264(frame))
        }
        lan.onCommand = { [weak self] command in self?.route(command) }
        lan.onFilePacket = { [weak self] transfer in
            self?.notePeerActivity()
            self?.onFilePacket?(transfer)
        }
        lan.onLocalNetworkStateChanged = { [weak self] state in
            self?.onLocalNetworkStateChanged?(state)
        }
        lan.onPairingCodeRequired = { [weak self] macName, error in
            self?.fallbackWorkItem?.cancel()
            self?.stopMultipeerFallback()
            self?.onPairingCodeRequired?(macName, error)
        }
        lan.onDiscoveredMacsChanged = { [weak self] names in
            guard let self else { return }
            self.lanDiscoveredMacs = Set(names)
            self.publishDiscoveredMacs()
        }
        lan.onConnectionChanged = { [weak self] connected, value in
            guard let self else { return }
            // A queued main-actor delivery belongs to the old route. Drop it
            // before publishing the new state so a late callback cannot paint
            // a stale frame after the viewer has been flushed.
            self.discardPendingVideoDelivery()
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
        // Restart is used for an explicit retry/forget action. Do not leave
        // the previous dial consent armed while discovery is rebuilt; a
        // discovered Mac must remain passive until the user taps Connect.
        userRequestedConnection = false
        selectedMacName = nil
        discardPendingVideoDelivery()
        fallbackWorkItem?.cancel()
        stopMultipeerFallback()
        invitedPeers.removeAll()
        lan.restart()
        scheduleMultipeerFallback()
    }

    func selectMac(named name: String) {
        userRequestedConnection = true
        selectedMacName = name
        invitedPeers.removeAll()
        lan.setMultipeerAdvertisedHosts(
            multipeerDiscoveredHosts[name] ?? [],
            forMacName: name
        )
        lan.selectMac(named: name)
        if let peer = multipeerDiscoveredMacs[name], let browser {
            invite(peer, using: browser)
        }
    }

    /// Stops discovery from dialing a previously selected Mac. Discovery can
    /// continue publishing device rows; a new connection starts only after
    /// the user selects a row again.
    func clearMacSelection() {
        userRequestedConnection = false
        selectedMacName = nil
        invitedPeers.removeAll()
        lan.clearSelectedMac()
        if mcConnected || !session.connectedPeers.isEmpty {
            session.disconnect()
        }
        mcConnected = false
        mcPeerName = nil
        discardPendingVideoDelivery()
        clearPendingMultipeerAuthentication()
    }

    private func enqueueVideoDelivery(_ delivery: PendingVideoDelivery) {
        videoDeliveryLock.lock()
        switch delivery {
        case .jpeg:
            // JPEG frames do not depend on one another. Keep only the newest
            // fallback image and reset any H.264 recovery gate if the route
            // changes back to the legacy transport.
            pendingVideoDeliveries.removeAll(keepingCapacity: true)
            pendingVideoDeliveryHead = 0
            waitingForH264KeyFrame = false
            pendingVideoDeliveries.append(delivery)

        case .h264(let frame):
            if waitingForH264KeyFrame {
                // The queue was forced to recover after an overflow. Do not
                // feed another P-frame into a decoder with a missing parent.
                guard frame.isKeyFrame else {
                    videoDeliveryLock.unlock()
                    return
                }
                waitingForH264KeyFrame = false
                pendingVideoDeliveries.removeAll(keepingCapacity: true)
                pendingVideoDeliveryHead = 0
            } else if pendingVideoDeliveryHead < pendingVideoDeliveries.count,
                      pendingVideoDeliveries[pendingVideoDeliveryHead...].contains(where: {
                          if case .jpeg = $0 { return true }
                          return false
                      }) {
                // A fresh H.264 stream supersedes a stale JPEG fallback.
                pendingVideoDeliveries.removeAll(keepingCapacity: true)
                pendingVideoDeliveryHead = 0
            }

            pendingVideoDeliveries.append(.h264(frame))
            let pendingCount = pendingVideoDeliveries.count - pendingVideoDeliveryHead
            if pendingCount > StreamCadencePolicy.receiverPendingWindow(for: frame.frameRate) {
                // Retain the newest IDR and everything after it. If no IDR is
                // present, wait for the encoder's next periodic key frame.
                if let keyIndex = pendingVideoDeliveries.lastIndex(where: {
                    if case .h264(let candidate) = $0 { return candidate.isKeyFrame }
                    return false
                }), keyIndex >= pendingVideoDeliveryHead {
                    pendingVideoDeliveryHead = keyIndex
                } else {
                    pendingVideoDeliveries.removeAll(keepingCapacity: true)
                    pendingVideoDeliveryHead = 0
                    waitingForH264KeyFrame = true
                }
            }
        }

        let generation = videoDeliveryGeneration
        let shouldSchedule = !videoDeliveryScheduled &&
            pendingVideoDeliveryHead < pendingVideoDeliveries.count
        if shouldSchedule { videoDeliveryScheduled = true }
        videoDeliveryLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainVideoDelivery(generation: generation)
        }
    }

    private func drainVideoDelivery(generation: UInt64) {
        videoDeliveryLock.lock()
        guard generation == videoDeliveryGeneration else {
            videoDeliveryLock.unlock()
            return
        }
        // Yield to input, SwiftUI, and the display layer between small video
        // batches. Larger high-cadence batches cut main-queue scheduling
        // overhead without allowing a burst to monopolize the actor.
        let batchLimit: Int
        let firstPending = pendingVideoDeliveryHead < pendingVideoDeliveries.count
            ? pendingVideoDeliveries[pendingVideoDeliveryHead]
            : nil
        switch firstPending {
        case .h264(let frame) where frame.frameRate >= 90:
            batchLimit = 8
        case .jpeg:
            batchLimit = 1
        default:
            batchLimit = 4
        }
        let pendingCount = pendingVideoDeliveries.count - pendingVideoDeliveryHead
        let deliveryCount = min(batchLimit, pendingCount)
        let deliveryStart = pendingVideoDeliveryHead
        let deliveryEnd = deliveryStart + deliveryCount
        let deliveries = Array(pendingVideoDeliveries[deliveryStart..<deliveryEnd])
        pendingVideoDeliveryHead = deliveryEnd
        if pendingVideoDeliveryHead == pendingVideoDeliveries.count {
            pendingVideoDeliveries.removeAll(keepingCapacity: true)
            pendingVideoDeliveryHead = 0
        } else if pendingVideoDeliveryHead >= 32 {
            pendingVideoDeliveries.removeSubrange(0..<pendingVideoDeliveryHead)
            pendingVideoDeliveryHead = 0
        }
        videoDeliveryScheduled = false
        let shouldReschedule = pendingVideoDeliveryHead < pendingVideoDeliveries.count
        if shouldReschedule { videoDeliveryScheduled = true }
        videoDeliveryLock.unlock()

        for delivery in deliveries {
            videoDeliveryLock.lock()
            let stillCurrent = generation == videoDeliveryGeneration
            videoDeliveryLock.unlock()
            guard stillCurrent else { return }
            switch delivery {
            case .jpeg(let frame):
                onFrame?(frame)
            case .h264(let frame):
                onVideoFrame?(frame)
            }
        }

        guard shouldReschedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainVideoDelivery(generation: generation)
        }
    }

    private func discardPendingVideoDelivery() {
        videoDeliveryLock.lock()
        pendingVideoDeliveries.removeAll(keepingCapacity: true)
        pendingVideoDeliveryHead = 0
        waitingForH264KeyFrame = false
        videoDeliveryGeneration &+= 1
        videoDeliveryScheduled = false
        videoDeliveryLock.unlock()
    }

    /// Drop packets queued before the app returned to the foreground. They
    /// can be valid network packets but still be unusable after iPadOS/PiP
    /// recreated the display layer. Gate H.264 delivery until the Mac answers
    /// the foreground keyframe request; an independent JPEG frame clears the
    /// gate when the legacy fallback is active.
    func prepareForForegroundResume() {
        videoDeliveryLock.lock()
        pendingVideoDeliveries.removeAll(keepingCapacity: true)
        pendingVideoDeliveryHead = 0
        waitingForH264KeyFrame = true
        videoDeliveryGeneration &+= 1
        videoDeliveryScheduled = false
        videoDeliveryLock.unlock()
    }

    func prepareForBackground() {
        applicationIsBackgrounded = true
        resumeGraceUntil = 0
        validationWorkItem?.cancel()
        validationWorkItem = nil
        heartbeatSentAt.removeAll(keepingCapacity: true)
        onConnectionHealthChanged?("Session suspended — preserving encrypted link", nil)
    }

    private func publishDiscoveredMacs() {
        let names = lanDiscoveredMacs.union(multipeerDiscoveredMacs.keys).sorted()
        onDiscoveredMacsChanged?(names)
    }

    private func invite(_ peerID: MCPeerID, using browser: MCNearbyServiceBrowser) {
        guard !invitedPeers.contains(peerID.displayName),
              session.connectedPeers.isEmpty else { return }
        invitedPeers.insert(peerID.displayName)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        pendingMCPrivateKey = privateKey
        mcSecureSession = nil
        let context = MultipeerInvitationContext(
            protocolVersion: LANWire.securityProtocolVersion,
            identity: PadDeviceIdentity.current,
            clientPublicKey: privateKey.publicKey.rawRepresentation
        )
        let encodedContext = try? JSONEncoder().encode(context)
        browser.invitePeer(peerID, to: session, withContext: encodedContext, timeout: 30)
        armMultipeerConnectionWatchdog(for: peerID.displayName)
    }

    func resumeAfterBackground() {
        // iPadOS may suspend the process while the user is in another app.
        // Returning from background may restore the remembered session, but
        // it must never turn passive discovery into an unsolicited dial.
        guard userRequestedConnection else { return }
        applicationIsBackgrounded = false
        let now = ProcessInfo.processInfo.systemUptime
        setLastPeerActivity(now)
        resumeGraceUntil = now + 15
        guard lanConnected || mcConnected else {
            onConnectionHealthChanged?("Restoring remembered Mac session", nil)
            lan.resumeAfterBackground()
            restartMultipeerBrowserAfterDisconnect()
            return
        }
        onConnectionHealthChanged?("Verifying after background", nil)
        let token = sendHeartbeatPing()
        let sentAt = heartbeatSentAt[token] ?? ProcessInfo.processInfo.systemUptime
        validationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.heartbeatSentAt[token] != nil else { return }
            self.heartbeatSentAt.removeValue(forKey: token)
            // A live session must produce either the heartbeat pong or other
            // encrypted traffic. Older Mac builds may not advertise heartbeat
            // support, so do not treat a silent socket as healthy merely
            // because `peerSupportsHeartbeat` is still false. Rebuilding the
            // selected direct/P2P path here is what makes swipe-away/return
            // reliable after iPadOS has suspended the socket.
            if self.peerActivityTimestamp() <= sentAt {
                self.recoverStaleConnection(reason: "No encrypted traffic after returning from background.")
            } else {
                self.resumeGraceUntil = 0
                self.onConnectionHealthChanged?("Encrypted link healthy", nil)
            }
        }
        validationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    func send(_ message: ControlMessage) {
        if lanConnected {
            lan.send(message)
        } else if mcConnected,
                  !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.control(message)) {
            sendMultipeerPacket(data, to: session.connectedPeers, mode: .reliable)
        }
    }

    func sendInput(_ input: RemoteInputEvent) {
        if lanConnected {
            lan.sendInput(input)
            return
        }
        guard mcConnected, !session.connectedPeers.isEmpty else { return }

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
        } else if mcConnected,
                  !session.connectedPeers.isEmpty,
                  let data = try? PacketCodec.encode(.file(transfer)) {
            sendMultipeerPacket(data, to: session.connectedPeers, mode: .reliable)
        }
    }

    func submitPairingCode(_ code: String) {
        lan.submitPairingCode(code)
        submittedMCPairingCode = PairingCode.normalize(code)
        sendMultipeerPairingResponseIfPossible()
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
        guard mcConnected, !peers.isEmpty else {
            pendingMultipeerInput.removeAll()
            return
        }

        while let input = pendingMultipeerInput.popFirst() {
            guard let message = ControlMessage.input(input),
                  let data = try? PacketCodec.encode(.control(message)) else { continue }
            let mode: MCSessionSendDataMode = input.isCoalescibleInput ? .unreliable : .reliable
            sendMultipeerPacket(data, to: peers, mode: mode)
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
            resumeGraceUntil = 0
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
        setLastPeerActivity(ProcessInfo.processInfo.systemUptime)
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
        if now < resumeGraceUntil {
            // The route may be ready before its first packet is deliverable.
            // Let the foreground resume validator own recovery during this
            // short handoff instead of declaring the session stale.
            return
        }
        if RemoteSessionLifecyclePolicy.shouldRecoverStaleConnection(
            isViewerBackgrounded: applicationIsBackgrounded,
            peerSupportsHeartbeat: peerSupportsHeartbeat,
            secondsSinceActivity: now - peerActivityTimestamp()
        ) {
            recoverStaleConnection(reason: "Encrypted link stopped responding.")
            return
        }
        guard !applicationIsBackgrounded else { return }
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
        setLastPeerActivity(ProcessInfo.processInfo.systemUptime)
    }

    private func setLastPeerActivity(_ timestamp: TimeInterval) {
        activityLock.lock()
        lastPeerActivity = timestamp
        activityLock.unlock()
    }

    private func peerActivityTimestamp() -> TimeInterval {
        activityLock.lock()
        let timestamp = lastPeerActivity
        activityLock.unlock()
        return timestamp
    }

    private func recoverStaleConnection(reason: String) {
        resumeGraceUntil = 0
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
        clearPendingMultipeerAuthentication()
        invitedPeers.removeAll()
    }

    private func armMultipeerConnectionWatchdog(
        for peerName: String,
        timeout: TimeInterval = 20
    ) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
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

    private func handleMultipeerAuthentication(_ message: PairingMessage, from remotePeer: MCPeerID) {
        switch message.kind {
        case .challenge:
            guard message.protocolVersion == LANWire.securityProtocolVersion,
                  let macID = message.macID,
                  let nonce = message.nonce,
                  let serverPublicKey = message.ephemeralPublicKey,
                  let privateKey = pendingMCPrivateKey else {
                session.disconnect()
                clearPendingMultipeerAuthentication()
                return
            }
            let clientPublicKey = privateKey.publicKey.rawRepresentation
            do {
                mcSecureSession = try SecurePacketSession.keyAgreement(
                    privateKey: privateKey,
                    peerPublicKey: serverPublicKey,
                    clientPublicKey: clientPublicKey,
                    serverPublicKey: serverPublicKey,
                    role: .client,
                    context: "SidecarBridge-Multipeer-v3"
                )
            } catch {
                session.disconnect()
                clearPendingMultipeerAuthentication()
                onConnectionChanged?(false, error.localizedDescription)
                return
            }
            pendingMCPeer = remotePeer
            pendingMCMacID = macID
            pendingMCNonce = nonce
            pendingMCChannelBinding = PairingProof.multipeerChannelBinding(
                clientPublicKey: clientPublicKey,
                serverPublicKey: serverPublicKey
            )
            sendMultipeerPairingResponseIfPossible()

        case .accepted:
            guard message.protocolVersion == LANWire.securityProtocolVersion,
                  let proof = message.proof,
                  let secret = pendingMCSecret,
                  let macID = pendingMCMacID,
                  let nonce = pendingMCNonce,
                  let channelBinding = pendingMCChannelBinding,
                  PairingProof.verify(
                    proof,
                    secret: secret,
                    role: .server,
                    identity: PadDeviceIdentity.current,
                    macID: macID,
                    nonce: nonce,
                    channelBinding: channelBinding
                  ) else {
                session.disconnect()
                clearPendingMultipeerAuthentication()
                onConnectionChanged?(false, "The nearby Mac could not be authenticated.")
                return
            }
            if let credential = message.credential {
                guard SecureCredentialStore.set(credential, account: "pad.mac.\(macID)") else {
                    session.disconnect()
                    clearPendingMultipeerAuthentication()
                    onConnectionChanged?(false, "The trusted Mac credential could not be saved in Keychain.")
                    return
                }
            }
            mcConnectionWatchdog?.cancel()
            mcConnectionWatchdog = nil
            mcConnected = true
            mcPeerName = remotePeer.displayName
            clearPendingMultipeerAuthentication()
            reportConnection()
            updateHeartbeatState()

        case .rejected:
            // A saved credential can become stale when the pairing transcript
            // changes between app versions. Remove only this Mac's entry so a
            // code submission is actually used on the retry; otherwise the
            // same rejected credential would be selected again forever.
            if usedSavedMCCredential, let macID = pendingMCMacID {
                SecureCredentialStore.remove(account: "pad.mac.\(macID)")
                usedSavedMCCredential = false
            }
            submittedMCPairingCode = nil
            pendingMCSecret = nil
            onPairingCodeRequired?(
                remotePeer.displayName,
                message.detail ?? "The one-time code was not accepted."
            )

        case .response:
            break
        }
    }

    private func sendMultipeerPairingResponseIfPossible() {
        guard !mcConnected,
              let remotePeer = pendingMCPeer,
              session.connectedPeers.contains(remotePeer),
              let macID = pendingMCMacID,
              let nonce = pendingMCNonce,
              let channelBinding = pendingMCChannelBinding else { return }

        let account = "pad.mac.\(macID)"
        let secret: Data
        if let credential = SecureCredentialStore.data(account: account) {
            secret = credential
            usedSavedMCCredential = true
        } else if let code = submittedMCPairingCode,
                  code.count == PairingCode.characterCount {
            secret = Data(code.utf8)
            usedSavedMCCredential = false
        } else {
            onPairingCodeRequired?(
                remotePeer.displayName,
                submittedMCPairingCode == nil
                    ? nil
                    : "Enter the complete 16-digit code shown on the Mac."
            )
            return
        }

        pendingMCSecret = secret
        let proof = PairingProof.make(
            secret: secret,
            role: .client,
            identity: PadDeviceIdentity.current,
            macID: macID,
            nonce: nonce,
            channelBinding: channelBinding
        )
        let response = PairingMessage(
            kind: .response,
            protocolVersion: LANWire.securityProtocolVersion,
            identity: PadDeviceIdentity.current,
            proof: proof
        )
        do {
            let packet = try PacketCodec.encode(.authentication(response))
            guard let mcSecureSession else { throw SecurePacketSession.SecurePacketError.invalidEnvelope }
            try session.send(
                mcSecureSession.seal(packet),
                toPeers: [remotePeer],
                with: .reliable
            )
        } catch {
            session.disconnect()
            clearPendingMultipeerAuthentication()
            onConnectionChanged?(false, error.localizedDescription)
        }
    }

    private func clearPendingMultipeerAuthentication() {
        pendingMCPeer = nil
        pendingMCMacID = nil
        pendingMCNonce = nil
        pendingMCChannelBinding = nil
        pendingMCSecret = nil
        pendingMCPrivateKey = nil
        submittedMCPairingCode = nil
        usedSavedMCCredential = false
        if !mcConnected {
            mcSecureSession = nil
        }
    }

    private func sendMultipeerPacket(
        _ packet: Data,
        to peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) {
        guard let mcSecureSession,
              let encrypted = try? mcSecureSession.seal(packet) else { return }
        do {
            try session.send(encrypted, toPeers: peers, with: mode)
        } catch {
            let delivery = mode == .reliable ? "reliable" : "unreliable"
            print("[SidecarBridge/P2P] send \(delivery) packet failed: \(error.localizedDescription)")
        }
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
            guard let self, let browser, self.browser === browser else { return }
            let name = peerID.displayName
            let hosts = BridgeNetworkMetadata.decodePrivateIPv4Addresses(
                info?[BridgeConstants.hostsTXTKey]
            )
            self.multipeerDiscoveredHosts[name] = hosts
            self.lan.setMultipeerAdvertisedHosts(hosts, forMacName: name)
            self.multipeerDiscoveredMacs[name] = peerID
            self.publishDiscoveredMacs()
            if self.userRequestedConnection, self.selectedMacName == name {
                self.invite(peerID, using: browser)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.invitedPeers.remove(peerID.displayName)
            self?.multipeerDiscoveredMacs.removeValue(forKey: peerID.displayName)
            self?.multipeerDiscoveredHosts.removeValue(forKey: peerID.displayName)
            self?.publishDiscoveredMacs()
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
            if state == .connected {
                self.mcConnected = false
                self.mcPeerName = nil
                self.pendingMCPeer = peerID
                self.armMultipeerConnectionWatchdog(for: peerID.displayName, timeout: 60)
            } else if state == .connecting {
                self.armMultipeerConnectionWatchdog(for: peerID.displayName)
            } else {
                self.mcConnected = false
                self.mcPeerName = nil
                self.discardPendingVideoDelivery()
                self.clearPendingMultipeerAuthentication()
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
                self.pendingMultipeerInput.removeAll()
                self.multipeerInputDrainScheduled = false
                self.invitedPeers.remove(peerID.displayName)
                self.restartMultipeerBrowserAfterDisconnect()
            }
            if state != .connected { self.reportConnection() }
            self.updateHeartbeatState()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= LANWire.maximumPayloadSize + SecurePacketSession.envelopeOverhead else {
            session.disconnect()
            return
        }
        if !SecurePacketSession.isEnvelope(data) {
            guard !mcConnected,
                  let packet = try? PacketCodec.decode(data),
                  case .authentication(let message) = packet,
                  message.kind == .challenge else {
                session.disconnect()
                return
            }
            DispatchQueue.main.async {
                self.handleMultipeerAuthentication(message, from: peerID)
            }
            return
        }
        guard let mcSecureSession else {
            session.disconnect()
            return
        }
        let packet: BridgePacket
        do {
            packet = try PacketCodec.decode(mcSecureSession.open(data))
        } catch {
            session.disconnect()
            return
        }
        if case .authentication(let message) = packet {
            DispatchQueue.main.async {
                self.handleMultipeerAuthentication(message, from: peerID)
            }
            return
        }
        guard mcConnected else {
            session.disconnect()
            return
        }
        switch packet {
        case .control(let command):
            DispatchQueue.main.async { self.route(command) }
        case .jpeg(let frame):
            self.notePeerActivity()
            self.enqueueVideoDelivery(.jpeg(frame))
        case .video(let frame):
            self.notePeerActivity()
            self.enqueueVideoDelivery(.h264(frame))
        case .authentication:
            break
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
