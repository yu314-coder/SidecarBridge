import Foundation
import MultipeerConnectivity
import UIKit

final class PadPeerService: NSObject {
    var onFrame: ((Data) -> Void)?
    var onVideoFrame: ((VideoFrame) -> Void)?
    var onCommand: ((ControlMessage) -> Void)?
    var onConnectionChanged: ((Bool, String?) -> Void)?
    var onLocalNetworkStateChanged: ((LocalNetworkAccessState) -> Void)?

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
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
    private var browserRefreshWorkItem: DispatchWorkItem?
    private let idleBrowserRefreshInterval: TimeInterval = 45

    override init() {
        super.init()
        session.delegate = self
        lan.onFrame = { [weak self] frame in self?.onFrame?(frame) }
        lan.onVideoFrame = { [weak self] frame in self?.onVideoFrame?(frame) }
        lan.onCommand = { [weak self] command in self?.onCommand?(command) }
        lan.onLocalNetworkStateChanged = { [weak self] state in
            self?.onLocalNetworkStateChanged?(state)
        }
        lan.onConnectionChanged = { [weak self] connected, value in
            guard let self else { return }
            self.lanConnected = connected
            if connected {
                self.lanPeerName = value
                self.fallbackWorkItem?.cancel()
                self.stopMultipeerFallback()
            } else {
                self.lanPeerName = nil
                self.scheduleMultipeerFallback()
            }
            self.reportConnection(error: connected ? nil : value)
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
        } else if !session.connectedPeers.isEmpty,
                  let message = ControlMessage.input(input),
                  let data = try? PacketCodec.encode(.control(message)) {
            let mode: MCSessionSendDataMode = (input.kind == .pointerMove || input.kind == .scroll) ? .unreliable : .reliable
            try? session.send(data, toPeers: session.connectedPeers, with: mode)
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
            self.armIdleBrowserRefresh()
        }
        fallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func stopMultipeerFallback() {
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        mcConnectionWatchdog?.cancel()
        mcConnectionWatchdog = nil
        browserRefreshWorkItem?.cancel()
        browserRefreshWorkItem = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    /// MCNearbyServiceBrowser can occasionally keep running without producing
    /// callbacks after an interface change. Keep a long stable discovery
    /// window before cycling it so a valid advertisement can be resolved.
    private func armIdleBrowserRefresh() {
        browserRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.started,
                  !self.lanConnected,
                  !self.mcConnected,
                  self.browserRunning,
                  self.invitedPeers.isEmpty else { return }
            print("[SidecarBridge/P2P] No nearby peers; refreshing browser")
            self.browser?.stopBrowsingForPeers()
            self.browserRunning = false
            self.browser?.delegate = nil
            self.browser = nil
            self.browserRefreshWorkItem = nil
            self.onConnectionChanged?(false, "Refreshing nearby P2P discovery automatically.")
            self.scheduleMultipeerFallback()
        }
        browserRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + idleBrowserRefreshInterval, execute: workItem)
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
        guard !invitedPeers.contains(peerID.displayName), session.connectedPeers.isEmpty else { return }
        browserRefreshWorkItem?.cancel()
        browserRefreshWorkItem = nil
        print("[SidecarBridge/P2P] Found and inviting \(peerID.displayName)")
        invitedPeers.insert(peerID.displayName)
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        armMultipeerConnectionWatchdog(for: peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        invitedPeers.remove(peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            guard self.browser === browser else { return }
            self.browserRefreshWorkItem?.cancel()
            self.browserRefreshWorkItem = nil
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
            print("[SidecarBridge/P2P] Session with \(peerID.displayName): \(state.rawValue)")
            self.mcConnected = !session.connectedPeers.isEmpty
            self.mcPeerName = self.mcConnected ? (session.connectedPeers.first?.displayName ?? peerID.displayName) : nil
            if state == .connected {
                self.browserRefreshWorkItem?.cancel()
                self.browserRefreshWorkItem = nil
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
            } else if state == .connecting {
                self.armMultipeerConnectionWatchdog(for: peerID.displayName)
            } else {
                self.mcConnectionWatchdog?.cancel()
                self.mcConnectionWatchdog = nil
                self.invitedPeers.remove(peerID.displayName)
                self.restartMultipeerBrowserAfterDisconnect()
            }
            self.reportConnection()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? PacketCodec.decode(data) else { return }
        switch packet {
        case .control(let command):
            DispatchQueue.main.async { self.onCommand?(command) }
        case .jpeg(let frame):
            DispatchQueue.main.async { self.onFrame?(frame) }
        case .video(let frame):
            DispatchQueue.main.async { self.onVideoFrame?(frame) }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
