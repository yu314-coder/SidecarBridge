import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI

@MainActor
final class MacConnectionModel: ObservableObject {
    @Published var status = "Starting…"
    @Published var detail = "Looking for your iPad."
    @Published var isStreaming = false
    @Published var hasPadPeer = false
    @Published var reachableSidecarDevices: [String] = []
    @Published var pairedPeer: String?
    @Published var launchAtLogin = false
    @Published var launchAtLoginNeedsApproval = false
    @Published var launchAtLoginDetail = "Checking macOS Login Items…"
    @Published var remoteInputAuthorized = false
    @Published var screenRecordingAuthorized = false
    @Published var localNetworkAccess: LocalNetworkAccessState = .checking
    @Published var connectionTransport = "Direct P2P preferred"
    @Published var connectionHealthDetail = "Waiting for encrypted link"
    @Published var connectionLatencyMS: Int?
    @Published var p2pState: MacP2PState = .starting
    @Published var fileTransferSnapshot: FileTransferSnapshot?
    @Published var lastReceivedFile: URL?
    @Published var fileTransferError: String?

    var localNetworkPermissionNeeded: Bool { localNetworkAccess.needsPermission }

    private let sidecar = SidecarConnector()
    private let peers = MacPeerService()
    private let streamer = ScreenStreamer()
    private let remoteInput = RemoteInputPipeline()
    private lazy var fileTransfer = FileTransferEngine {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return downloads.appendingPathComponent("SidecarBridge Transfers", isDirectory: true)
    }
    private var started = false
    private var isStartingFallback = false
    private var attemptID = UUID()
    private var accessibilityPollTask: Task<Void, Never>?
    private var screenRecordingPollTask: Task<Void, Never>?

    init() {
        pairedPeer = UserDefaults.standard.string(forKey: "pairedPeerName")
        refreshLaunchAtLoginStatus()
        remoteInputAuthorized = remoteInput.isAuthorized
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()

        peers.onLocalNetworkStateChanged = { [weak self] state in
            guard let self else { return }
            self.localNetworkAccess = state
            if state.needsPermission && !self.hasPadPeer {
                self.status = "Allow Local Network access"
                self.detail = "macOS blocked direct discovery. Turn on SidecarBridge in Privacy & Security → Local Network."
            }
        }

        peers.onP2PStateChanged = { [weak self] state in
            self?.p2pState = state
        }

        peers.onConnectionHealthChanged = { [weak self] detail, latency in
            self?.connectionHealthDetail = detail
            self?.connectionLatencyMS = latency
        }

        peers.onConnectionChanged = { [weak self] connected, peerOrError in
            guard let self else { return }
            self.hasPadPeer = connected
            if connected {
                let isDirectLAN = peerOrError?.hasPrefix("LAN:") == true
                self.streamer.setTransportProfile(isDirectLAN ? .direct : .nearbyP2P)
                self.refreshPermissions()
                self.connectionTransport = isDirectLAN ? "Direct local link / AWDL" : "Nearby P2P fallback"
                self.status = isDirectLAN ? "iPad connected on same Wi-Fi" : "iPad app connected nearby"
                self.detail = isDirectLAN
                    ? "Waiting for the iPad's selected display mode. Apple Sidecar will not start automatically."
                    : "Waiting for the iPad's selected display mode."
                self.pairedPeer = UserDefaults.standard.string(forKey: "pairedPeerName")
                self.sendRemoteInputPermissionStatus()
            } else if let peerOrError {
                self.connectionHealthDetail = "Recovering connection"
                self.connectionLatencyMS = nil
                if peerOrError.localizedCaseInsensitiveContains("NoAuth") {
                    self.localNetworkAccess = .denied
                    self.status = "Allow Local Network access"
                    self.detail = "macOS blocked same-Wi-Fi discovery. Turn on SidecarBridge in Privacy & Security → Local Network."
                } else {
                    self.status = "Nearby connection unavailable"
                    self.detail = peerOrError
                }
                self.connectionTransport = "Searching direct P2P"
                self.fileTransfer.cancelAll(reason: "Connection ended.")
                self.remoteInput.releaseButtons()
                self.stopFallback()
            } else {
                self.connectionHealthDetail = "Waiting for encrypted link"
                self.connectionLatencyMS = nil
                self.connectionTransport = "Searching direct P2P"
                self.status = "Waiting for iPad"
                self.detail = "Open SidecarBridge on the iPad."
                self.remoteInput.releaseButtons()
                self.fileTransfer.cancelAll(reason: "Connection ended.")
                self.stopFallback()
            }
        }
        let inputPipeline = remoteInput
        let peerService = peers
        peers.onInput = { [weak self] event in
            inputPipeline.submit(event) { accepted in
                if event.shouldAcknowledge, let sequence = event.sequence {
                    peerService.send(ControlMessage(
                        .status,
                        detail: "input-ack:\(sequence):\(accepted ? 1 : 0)"
                    ))
                }
                DispatchQueue.main.async { [weak self] in
                    self?.applyRemoteInputResult(accepted)
                }
            }
        }
        peers.onCommand = { [weak self] command in self?.handle(command) }
        peers.onFilePacket = { [weak self] transfer in self?.fileTransfer.handle(transfer) }
        streamer.onFrame = { [weak peers] frame in peers?.sendVideoFrame(frame) }
        configureFileTransfer()
    }

    var isFileTransferring: Bool { fileTransfer.isBusy }

    func chooseFileToSend() {
        guard hasPadPeer else {
            fileTransferError = "Connect the iPad before sending a file."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Send a File to iPad"
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileTransferError = nil
        fileTransfer.sendFile(at: url)
    }

    func revealLastReceivedFile() {
        guard let lastReceivedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastReceivedFile])
    }

    private func configureFileTransfer() {
        fileTransfer.sendPacket = { [weak self] packet in self?.peers.sendFilePacket(packet) }
        fileTransfer.onSnapshot = { [weak self] snapshot in self?.fileTransferSnapshot = snapshot }
        fileTransfer.onReceived = { [weak self] url in
            self?.lastReceivedFile = url
            self?.fileTransferError = nil
        }
        fileTransfer.onError = { [weak self] message in self?.fileTransferError = message }
    }

    func start() {
        guard !started else { return }
        started = true
        repairLaunchAtLoginIfNeeded()
        refreshPermissions()
        peers.start()
        refreshDevices()
        status = "Waiting for iPad"
        detail = "Open SidecarBridge on the iPad. Its selected mode decides whether to use the app stream or Apple Sidecar."
    }

    var p2pDetail: String {
        switch p2pState {
        case .starting:
            return "Starting nearby encrypted discovery"
        case .advertising:
            return "Ready for a nearby iPad connection"
        case .connecting(let peer):
            return "Negotiating an encrypted session with \(peer)"
        case .connected(let peer):
            return "Nearby encrypted link active with \(peer)"
        case .recovering(let reason):
            return reason
        case .standbyDirect:
            return "Standby — direct Wi-Fi/AWDL link is active"
        }
    }

    var p2pBadge: String {
        switch p2pState {
        case .starting: return "STARTING"
        case .advertising: return "READY"
        case .connecting: return "CONNECTING"
        case .connected: return "ACTIVE"
        case .recovering: return "RECOVERING"
        case .standbyDirect: return "STANDBY"
        }
    }

    var p2pIsReady: Bool {
        switch p2pState {
        case .advertising, .connected, .standbyDirect: return true
        case .starting, .connecting, .recovering: return false
        }
    }

    var p2pIsChecking: Bool { !p2pIsReady }

    func trySidecarNow() {
        refreshDevices()
        attemptNative(preferredName: nil, allowFallback: hasPadPeer)
    }

    func startFallback() {
        // Invalidate callbacks from any older native attempt. The app-stream
        // mode must never launch Apple Continuity on its own.
        attemptID = UUID()
        guard hasPadPeer else {
            status = "Open the iPad app first"
            detail = "The private stream starts after the two apps find each other."
            return
        }
        guard !isStreaming, !isStartingFallback else { return }

        refreshPermissions()
        if !screenRecordingAuthorized {
            enableScreenRecording()
            guard screenRecordingAuthorized else {
                status = "Allow Screen Recording"
                detail = "Screen Recording must pass before the Mac display can be sent to the iPad."
                peers.send(ControlMessage(.status, detail: "fallback-error:Screen Recording permission is required on the Mac."))
                return
            }
        }
        isStartingFallback = true

        remoteInputAuthorized = remoteInput.requestAccess()
        sendRemoteInputPermissionStatus()

        status = "Starting app stream…"
        detail = "macOS may ask for Screen Recording permission."
        Task {
            do {
                try await streamer.start()
                isStartingFallback = false
                isStreaming = true
                screenRecordingAuthorized = true
                status = "Streaming to iPad"
                detail = "Using the encrypted app stream with iPad keyboard and trackpad input."
                peers.send(ControlMessage(.status, detail: "fallback-active"))
            } catch {
                isStartingFallback = false
                status = "App stream needs attention"
                detail = error.localizedDescription
                peers.send(ControlMessage(.status, detail: "fallback-error:\(error.localizedDescription)"))
            }
        }
    }

    func stopFallback() {
        remoteInput.releaseButtons()
        streamer.stop()
        isStartingFallback = false
        isStreaming = false
    }

    func openDisplaysSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermissions() {
        remoteInputAuthorized = remoteInput.isAuthorized
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
        if hasPadPeer { sendRemoteInputPermissionStatus() }
    }

    func enableScreenRecording() {
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if screenRecordingAuthorized {
            status = "Screen Recording enabled"
            detail = "The Mac screen is ready for the encrypted app stream."
        } else {
            status = "Allow Screen Recording"
            detail = "Enable SidecarBridge in Privacy & Security → Screen & System Audio Recording."
            openScreenRecordingSettings()
            pollForScreenRecordingAccess()
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        pollForScreenRecordingAccess()
    }

    func forgetPairing() {
        UserDefaults.standard.removeObject(forKey: "pairedPeerName")
        pairedPeer = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    openLoginItemsSettings()
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                @unknown default:
                    try SMAppService.mainApp.register()
                }
                if SMAppService.mainApp.status == .enabled {
                    UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemBundlePath")
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(forKey: "loginItemBundlePath")
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            status = "Could not change login setting"
            detail = error.localizedDescription
        }
    }

    func repairLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemBundlePath")
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemBundlePath")
            case .requiresApproval:
                openLoginItemsSettings()
            @unknown default:
                try SMAppService.mainApp.register()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            status = "Automatic startup needs attention"
            detail = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNeedsApproval = false
            let registeredPath = UserDefaults.standard.string(forKey: "loginItemBundlePath")
            if registeredPath == Bundle.main.bundlePath {
                launchAtLoginDetail = "On — SidecarBridge will start after you sign in."
            } else {
                launchAtLoginDetail = "On, but it may point to an older build. Click Repair."
            }
        case .requiresApproval:
            launchAtLogin = false
            launchAtLoginNeedsApproval = true
            launchAtLoginDetail = "macOS approval is required in Login Items."
        case .notRegistered:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
            launchAtLoginDetail = "Off — SidecarBridge must be opened manually."
        case .notFound:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
            launchAtLoginDetail = "Registration is missing. Click Repair Automatic Start."
        @unknown default:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
            launchAtLoginDetail = "Unknown macOS Login Item status."
        }
    }

    private func repairLaunchAtLoginIfNeeded() {
        guard SMAppService.mainApp.status == .enabled else { return }
        guard UserDefaults.standard.string(forKey: "loginItemBundlePath") != Bundle.main.bundlePath else { return }

        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemBundlePath")
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            status = "Automatic startup needs attention"
            detail = error.localizedDescription
        }
    }

    func enableRemoteInput() {
        remoteInputAuthorized = remoteInput.requestAccess()
        if remoteInputAuthorized {
            status = "Remote input enabled"
            detail = "The iPad Magic Keyboard and trackpad can control this Mac during app streaming."
            sendRemoteInputPermissionStatus()
        } else {
            status = "Allow Accessibility access"
            detail = "In Accessibility, click + and select this SidecarBridge app. Use Show App if you cannot find it."
            remoteInput.openAccessibilitySettings()
            pollForAccessibilityAccess()
        }
    }

    func openAccessibilitySettings() {
        remoteInput.openAccessibilitySettings()
        pollForAccessibilityAccess()
    }

    func revealApplication() {
        remoteInput.revealApplication()
    }

    private func pollForAccessibilityAccess() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    guard let self else { return }
                    self.remoteInputAuthorized = true
                    self.status = "Remote input enabled"
                    self.detail = "The iPad Magic Keyboard and trackpad can control this Mac during app streaming."
                    self.sendRemoteInputPermissionStatus()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pollForScreenRecordingAccess() {
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = Task { [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                if CGPreflightScreenCaptureAccess() {
                    guard let self else { return }
                    self.screenRecordingAuthorized = true
                    self.status = "Screen Recording enabled"
                    self.detail = "The Mac screen is ready for the encrypted app stream."
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func handle(_ command: ControlMessage) {
        switch command.kind {
        case .hello:
            if let detail = command.detail,
               detail.hasPrefix("display-width:"),
               let width = Int(detail.dropFirst("display-width:".count)) {
                streamer.setPreferredWidth(width)
            }
        case .trySidecar:
            refreshDevices()
            attemptNative(preferredName: command.detail, allowFallback: true)
        case .startFallback:
            startFallback()
        case .stopFallback:
            stopFallback()
        case .status:
            if let detail = command.detail {
                if detail.hasPrefix("video-ack:"),
                   let sequence = UInt64(detail.dropFirst("video-ack:".count)) {
                    peers.acknowledgeVideo(sequence: sequence)
                } else if detail == "viewer-background" {
                    streamer.setViewerBackgrounded(true)
                } else if detail == "viewer-foreground" {
                    streamer.setViewerBackgrounded(false)
                }
            }
        case .input:
            guard let event = command.remoteInputEvent else { return }
            let peerService = peers
            remoteInput.submit(event) { [weak self] accepted in
                if event.shouldAcknowledge, let sequence = event.sequence {
                    peerService.send(ControlMessage(
                        .status,
                        detail: "input-ack:\(sequence):\(accepted ? 1 : 0)"
                    ))
                }
                DispatchQueue.main.async { [weak self] in
                    self?.applyRemoteInputResult(accepted)
                }
            }
        }
    }

    private func applyRemoteInputResult(_ accepted: Bool) {
        if !accepted {
            remoteInputAuthorized = false
            sendRemoteInputPermissionStatus()
        } else if !remoteInputAuthorized {
            remoteInputAuthorized = true
            sendRemoteInputPermissionStatus()
        }
    }

    private func sendRemoteInputPermissionStatus() {
        peers.send(ControlMessage(
            .status,
            detail: remoteInputAuthorized ? "accessibility-passed" : "accessibility-required"
        ))
    }

    private func refreshDevices() {
        reachableSidecarDevices = sidecar.reachableDeviceNames()
    }

    private func attemptNative(preferredName: String?, allowFallback: Bool) {
        stopFallback()
        let id = UUID()
        attemptID = id

        guard !reachableSidecarDevices.isEmpty else {
            status = "No native Sidecar iPad found"
            detail = "Trying the app stream instead."
            peers.send(ControlMessage(.status, detail: "sidecar-unavailable"))
            if allowFallback { startFallback() }
            return
        }

        let wired = CableDetector.isIPadConnected()
        let firstTransport: SidecarConnector.Transport = wired ? .wired : .wireless
        status = wired ? "Trying wired Sidecar…" : "Trying wireless Sidecar…"
        detail = wired ? "An iPad is visible on USB." : "No iPad cable was detected."
        peers.send(ControlMessage(.status, detail: wired ? "sidecar-wired" : "sidecar-wireless"))

        connectOnce(id: id, name: preferredName, transport: firstTransport) { [weak self] result in
            guard let self, self.attemptID == id else { return }
            switch result {
            case .success(let name):
                self.status = "Native Sidecar connected"
                self.detail = "Connected to \(name) using \(firstTransport.rawValue)."
                self.peers.send(ControlMessage(.status, detail: "sidecar-connected"))
            case .failure:
                if firstTransport == .wired {
                    self.status = "Wired failed; trying wireless…"
                    self.connectOnce(id: id, name: preferredName, transport: .wireless) { [weak self] retry in
                        self?.finishNativeAttempt(id: id, result: retry, transport: .wireless, allowFallback: allowFallback)
                    }
                } else {
                    self.finishNativeAttempt(id: id, result: result, transport: .wireless, allowFallback: allowFallback)
                }
            }
        }
    }

    private func connectOnce(
        id: UUID,
        name: String?,
        transport: SidecarConnector.Transport,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var finished = false
        sidecar.connect(preferredName: name, transport: transport) { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard self.attemptID == id, !finished else { return }
            finished = true
            completion(.failure(NSError(
                domain: "SidecarBridge",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey: "Sidecar connection timed out."]
            )))
        }
    }

    private func finishNativeAttempt(
        id: UUID,
        result: Result<String, Error>,
        transport: SidecarConnector.Transport,
        allowFallback: Bool
    ) {
        guard attemptID == id else { return }
        switch result {
        case .success(let name):
            status = "Native Sidecar connected"
            detail = "Connected to \(name) using \(transport.rawValue)."
            peers.send(ControlMessage(.status, detail: "sidecar-connected"))
        case .failure(let error):
            status = "Native Sidecar failed"
            detail = error.localizedDescription
            peers.send(ControlMessage(.status, detail: "sidecar-failed"))
            if allowFallback { startFallback() }
        }
    }
}
