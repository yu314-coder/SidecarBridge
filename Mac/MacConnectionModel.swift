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
    @Published var incomingListenerReady = false
    @Published var incomingListenerDetail = "Starting the encrypted local listener on TCP 45454…"
    @Published var connectionTransport = "Direct P2P preferred"
    @Published var connectionHealthDetail = "Waiting for encrypted link"
    @Published var connectionLatencyMS: Int?
    @Published var p2pState: MacP2PState = .starting
    @Published var fileTransferSnapshot: FileTransferSnapshot?
    @Published var lastReceivedFile: URL?
    @Published var fileTransferError: String?
    @Published var queuedFileCount = 0
    @Published var pairingCode = MacPairingSecurity.shared.currentDisplayCode()
    @Published var shortcutTestStatus = "Not tested in this Mac session"
    @Published var localSystemInformation = SystemInformation.current()
    @Published var remoteSystemInformation: SystemInformation?
    @Published var diagnosticActionDetail = "System information is ready."
    @Published var shutdownProtectionEnabled = true
    @Published var shutdownProtectionActive = false
    @Published var shutdownProtectionDetail = "Ready to preserve remote control during system shutdown."

    var localNetworkPermissionNeeded: Bool { localNetworkAccess.needsPermission }

    var menuBarStatusIcon: String {
        if isStreaming { return "dot.radiowaves.left.and.right" }
        if hasPadPeer { return "ipad.and.arrow.forward" }
        return "ipad.and.arrow.forward"
    }

    var menuBarStatusText: String {
        if isStreaming { return "Streaming to \(pairedPeer ?? "iPad")" }
        if hasPadPeer { return "Connected — ready to stream" }
        return status
    }

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
    #if !SIDECARBRIDGE_APP_STORE_SAFE
    private var accessibilityPollTask: Task<Void, Never>?
    #endif
    private var screenRecordingPollTask: Task<Void, Never>?
    private var streamResumeRetentionTask: Task<Void, Never>?
    private var remoteViewerIsBackgrounded = false
    private var pendingFileURLs: [URL] = []
    private let shutdownProtectionDefaultsKey = "shutdownProtectionEnabled"

    init() {
        if UserDefaults.standard.object(forKey: shutdownProtectionDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: shutdownProtectionDefaultsKey)
        }
        shutdownProtectionEnabled = UserDefaults.standard.bool(forKey: shutdownProtectionDefaultsKey)
        MacPairingSecurity.shared.onPairingCodeChanged = { [weak self] code in
            self?.pairingCode = code
        }
        pairedPeer = MacAuthorizedDeviceStore.shared.displaySummary
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

        peers.onListenerStateChanged = { [weak self] ready, detail in
            self?.incomingListenerReady = ready
            self?.incomingListenerDetail = detail
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
                self.cancelStreamResumeRetention()
                let isDirectLAN = peerOrError?.hasPrefix("LAN:") == true
                self.streamer.setTransportProfile(isDirectLAN ? .direct : .nearbyP2P)
                self.refreshPermissions()
                self.connectionTransport = isDirectLAN ? "Direct local link / AWDL" : "Nearby P2P fallback"
                self.status = isDirectLAN ? "iPad connected on same Wi-Fi" : "iPad app connected nearby"
                #if SIDECARBRIDGE_APP_STORE_SAFE
                self.detail = isDirectLAN
                    ? "Waiting for the iPad's selected viewer mode."
                    : "Waiting for the iPad's selected viewer mode."
                #else
                self.detail = isDirectLAN
                    ? "Waiting for the iPad's selected display mode. Apple Sidecar will not start automatically."
                    : "Waiting for the iPad's selected display mode."
                #endif
                self.pairedPeer = MacAuthorizedDeviceStore.shared.displaySummary
                self.sendRemoteInputPermissionStatus()
                self.exchangeSystemInformation()
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
                self.pendingFileURLs.removeAll(keepingCapacity: false)
                self.queuedFileCount = 0
                self.fileTransfer.cancelAll(reason: "Connection ended.")
                self.remoteInput.releaseButtons()
                self.remoteSystemInformation = nil
                self.retainStreamForViewerResumeIfNeeded()
            } else {
                self.connectionHealthDetail = "Waiting for encrypted link"
                self.connectionLatencyMS = nil
                self.connectionTransport = "Searching direct P2P"
                self.status = "Waiting for iPad"
                self.detail = "Open SidecarBridge on the iPad."
                self.remoteInput.releaseButtons()
                self.pendingFileURLs.removeAll(keepingCapacity: false)
                self.queuedFileCount = 0
                self.fileTransfer.cancelAll(reason: "Connection ended.")
                self.remoteSystemInformation = nil
                self.retainStreamForViewerResumeIfNeeded()
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
                    self?.recordShortcutResult(event, accepted: accepted, source: "iPad")
                }
            }
        }
        peers.onCommand = { [weak self] command in self?.handle(command) }
        peers.onFilePacket = { [weak self] transfer in self?.fileTransfer.handle(transfer) }
        streamer.onFrame = { [weak peers] frame in peers?.sendVideoFrame(frame) }
        peers.onKeyFrameNeeded = { [weak self] in self?.streamer.requestKeyFrame() }
        configureFileTransfer()
    }

    var isFileTransferring: Bool { fileTransfer.isBusy }

    func testControlShortcut(_ key: String) {
        guard ["up", "down", "left", "right"].contains(key) else { return }
        let event = RemoteInputEvent.key(key, modifiers: ["control"])
        remoteInput.submit(event) { [weak self] accepted in
            DispatchQueue.main.async {
                self?.recordShortcutResult(event, accepted: accepted, source: "Mac test")
            }
        }
    }

    func testModifierClick(_ modifiers: [String]) {
        let event = RemoteInputEvent.click(modifiers: modifiers)
        remoteInput.submit(event) { [weak self] accepted in
            DispatchQueue.main.async {
                let names = modifiers.map { $0.capitalized }.joined(separator: "–")
                self?.shortcutTestStatus = accepted
                    ? "Mac test: \(names)–click injected at the current pointer"
                    : "Mac test: \(names)–click rejected — check Accessibility"
            }
        }
    }

    private func recordShortcutResult(
        _ event: RemoteInputEvent,
        accepted: Bool,
        source: String
    ) {
        guard event.kind == .key,
              event.modifiers?.contains("control") == true,
              let key = event.key,
              ["up", "down", "left", "right"].contains(key) else { return }
        let arrow = ["up": "↑", "down": "↓", "left": "←", "right": "→"][key] ?? key
        shortcutTestStatus = accepted
            ? "\(source): Control-\(arrow) injected with HID timing"
            : "\(source): Control-\(arrow) rejected — check Accessibility"
    }

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
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        pendingFileURLs.append(contentsOf: panel.urls)
        queuedFileCount = pendingFileURLs.count
        fileTransferError = nil
        startNextQueuedFileIfNeeded()
    }

    func cancelFileTransfer() {
        pendingFileURLs.removeAll(keepingCapacity: false)
        queuedFileCount = 0
        guard fileTransfer.isBusy else { return }
        fileTransfer.cancelAll(reason: "Transfer canceled from the Mac.")
        fileTransferError = "Transfer canceled."
    }

    func openTransferFolder() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            fileTransferError = "The Downloads folder is unavailable."
            return
        }
        let directory = downloads.appendingPathComponent("SidecarBridge Transfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            fileTransferError = error.localizedDescription
        }
    }

    func revealLastReceivedFile() {
        guard let lastReceivedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastReceivedFile])
    }

    private func configureFileTransfer() {
        fileTransfer.sendPacket = { [weak self] packet in self?.peers.sendFilePacket(packet) }
        fileTransfer.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.fileTransferSnapshot = snapshot
            if snapshot?.direction == .sending, snapshot?.message == "Sent" {
                Task { @MainActor [weak self] in
                    self?.startNextQueuedFileIfNeeded()
                }
            }
        }
        fileTransfer.onReceived = { [weak self] url in
            self?.lastReceivedFile = url
            self?.fileTransferError = nil
        }
        fileTransfer.onError = { [weak self] message in
            self?.pendingFileURLs.removeAll(keepingCapacity: false)
            self?.queuedFileCount = 0
            self?.fileTransferError = message
        }
    }

    private func startNextQueuedFileIfNeeded() {
        guard hasPadPeer, !fileTransfer.isBusy, let next = pendingFileURLs.first else {
            queuedFileCount = pendingFileURLs.count
            return
        }
        pendingFileURLs.removeFirst()
        queuedFileCount = pendingFileURLs.count
        fileTransferError = nil
        fileTransfer.sendFile(at: next)
    }

    func start() {
        guard !started else { return }
        started = true
        repairLaunchAtLoginIfNeeded()
        refreshPermissions()
        peers.start()
        refreshDevices()
        status = "Waiting for iPad"
        #if SIDECARBRIDGE_APP_STORE_SAFE
        detail = "Open SidecarBridge on the iPad. Its selected mode decides whether to use the private viewer stream."
        #else
        detail = "Open SidecarBridge on the iPad. Its selected mode decides whether to use the app stream or Apple Sidecar."
        #endif
    }

    func setShutdownProtectionEnabled(_ enabled: Bool) {
        shutdownProtectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: shutdownProtectionDefaultsKey)
        shutdownProtectionDetail = enabled
            ? "Ready to preserve remote control during system shutdown."
            : "Off — SidecarBridge will quit when macOS asks it to."
    }

    func updateShutdownProtection(active: Bool, blockingApplications: [String]) {
        shutdownProtectionActive = active
        if blockingApplications.isEmpty {
            shutdownProtectionDetail = "Other apps are closed. Finishing shutdown…"
        } else {
            let visibleNames = blockingApplications.prefix(3).joined(separator: ", ")
            let remaining = max(0, blockingApplications.count - 3)
            shutdownProtectionDetail = remaining == 0
                ? "Remote control is staying online while \(visibleNames) closes."
                : "Remote control is staying online while \(visibleNames) and \(remaining) more close."
        }
    }

    func cancelShutdownProtection(reason: String) {
        shutdownProtectionActive = false
        shutdownProtectionDetail = reason
        status = "Shutdown needs attention"
        detail = reason
    }

    func prepareForTermination() {
        #if !SIDECARBRIDGE_APP_STORE_SAFE
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        #endif
        screenRecordingPollTask?.cancel()
        screenRecordingPollTask = nil
        streamResumeRetentionTask?.cancel()
        streamResumeRetentionTask = nil
        attemptID = UUID()
        pendingFileURLs.removeAll(keepingCapacity: false)
        queuedFileCount = 0
        fileTransfer.cancelAll(reason: "SidecarBridge is quitting.")
        remoteInput.releaseButtons()
        streamer.stop()
        peers.stop()
        isStreaming = false
        isStartingFallback = false
        started = false
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
        attemptNative(preferredName: nil, allowFallback: false)
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
        if isStreaming {
            cancelStreamResumeRetention()
            remoteViewerIsBackgrounded = false
            streamer.setViewerBackgrounded(false)
            streamer.setWaitingForViewerResume(false)
            streamer.requestKeyFrame()
            refreshPermissions()
            sendRemoteInputPermissionStatus()
            status = "Streaming to iPad"
            detail = "Resumed the retained encrypted app stream."
            peers.send(ControlMessage(.status, detail: "fallback-active"))
            return
        }
        guard !isStartingFallback else { return }

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

        #if SIDECARBRIDGE_APP_STORE_SAFE
        remoteInputAuthorized = false
        #else
        remoteInputAuthorized = remoteInput.requestAccess()
        #endif
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
                #if SIDECARBRIDGE_APP_STORE_SAFE
                detail = "Using the encrypted viewer stream. Full iPad keyboard and trackpad control is available in the direct companion build."
                #else
                detail = "Using the encrypted app stream with iPad keyboard and trackpad input."
                #endif
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
        streamResumeRetentionTask?.cancel()
        streamResumeRetentionTask = nil
        remoteViewerIsBackgrounded = false
        remoteInput.releaseButtons()
        streamer.setWaitingForViewerResume(false)
        streamer.setViewerBackgrounded(false)
        streamer.stop()
        isStartingFallback = false
        isStreaming = false
    }

    private func retainStreamForViewerResumeIfNeeded() {
        guard RemoteSessionLifecyclePolicy.shouldRetainStreamAfterDisconnect(
            isStreaming: isStreaming
        ) else {
            stopFallback()
            return
        }

        streamResumeRetentionTask?.cancel()
        remoteViewerIsBackgrounded = true
        streamer.setViewerBackgrounded(true)
        streamer.setWaitingForViewerResume(true)
        connectionHealthDetail = "Viewer suspended — stream retained for fast resume"
        status = "Waiting for iPad to return"
        detail = "Keeping a low-power capture session ready for five minutes."

        streamResumeRetentionTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(RemoteSessionLifecyclePolicy.streamResumeRetentionInterval)
            )
            guard !Task.isCancelled, let self, !self.hasPadPeer else { return }
            self.streamResumeRetentionTask = nil
            self.stopFallback()
            self.status = "Waiting for iPad"
            self.detail = "The fast-resume window ended. Reconnecting will start a new stream."
        }
    }

    private func cancelStreamResumeRetention() {
        streamResumeRetentionTask?.cancel()
        streamResumeRetentionTask = nil
        streamer.setWaitingForViewerResume(false)
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
        MacPairingSecurity.shared.forgetAllDevices()
        MacAuthorizedDeviceStore.shared.forgetAll()
        pairedPeer = nil
    }

    func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }

    func refreshSystemInformation() {
        localSystemInformation = SystemInformation.current()
        diagnosticActionDetail = hasPadPeer
            ? "Refreshed this Mac and requested the connected device."
            : "Refreshed this Mac. Connect an iPhone or iPad to see both devices."
        exchangeSystemInformation()
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport, forType: .string)
        diagnosticActionDetail = "Privacy-safe diagnostic report copied."
    }

    var diagnosticReport: String {
        var connectionFields = [
            DiagnosticField("Status", status),
            DiagnosticField("Transport", connectionTransport),
            DiagnosticField("Encrypted peer", hasPadPeer ? "Connected" : "Not connected"),
            DiagnosticField("Streaming", isStreaming ? "Active" : "Inactive"),
            DiagnosticField(
                "Round-trip latency",
                connectionLatencyMS.map { "\($0) ms" } ?? "Not measured"
            ),
            DiagnosticField("Link health", connectionHealthDetail),
            DiagnosticField(
                "Local Network permission",
                localNetworkAccess.isGranted ? "Passed" : localNetworkPermissionNeeded ? "Required" : "Checking"
            ),
            DiagnosticField(
                "Screen Recording permission",
                screenRecordingAuthorized ? "Passed" : "Required"
            )
        ]
        #if !SIDECARBRIDGE_APP_STORE_SAFE
        connectionFields.append(
            DiagnosticField(
                "Accessibility permission",
                remoteInputAuthorized ? "Passed" : "Required"
            )
        )
        #endif
        return DiagnosticReportBuilder.make(
            local: localSystemInformation,
            remote: remoteSystemInformation,
            connection: connectionFields
        )
    }

    private func exchangeSystemInformation() {
        guard hasPadPeer else { return }
        if let message = ControlMessage.systemInformation(localSystemInformation) {
            peers.send(message)
        }
        peers.send(.requestSystemInformation)
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
        #if SIDECARBRIDGE_APP_STORE_SAFE
        remoteInputAuthorized = false
        status = "Viewer-only Mac companion"
        detail = "Remote keyboard and trackpad control is available in the direct companion build."
        sendRemoteInputPermissionStatus()
        #else
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
        #endif
    }

    func openAccessibilitySettings() {
        #if SIDECARBRIDGE_APP_STORE_SAFE
        status = "Viewer-only Mac companion"
        detail = "The Mac App Store edition does not request Accessibility permission."
        #else
        remoteInput.openAccessibilitySettings()
        pollForAccessibilityAccess()
        #endif
    }

    func revealApplication() {
        #if SIDECARBRIDGE_APP_STORE_SAFE
        return
        #else
        remoteInput.revealApplication()
        #endif
    }

    #if !SIDECARBRIDGE_APP_STORE_SAFE
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
    #endif

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
                    remoteViewerIsBackgrounded = true
                    peers.setRemoteViewerBackgrounded(true)
                    streamer.setViewerBackgrounded(true)
                } else if detail == "viewer-foreground" {
                    remoteViewerIsBackgrounded = false
                    cancelStreamResumeRetention()
                    peers.setRemoteViewerBackgrounded(false)
                    streamer.setViewerBackgrounded(false)
                    if isStreaming {
                        streamer.requestKeyFrame()
                    }
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
        case .requestSystemInformation:
            localSystemInformation = SystemInformation.current()
            if let message = ControlMessage.systemInformation(localSystemInformation) {
                peers.send(message)
            }
        case .systemInformation:
            guard let information = command.systemInformationPayload else { return }
            remoteSystemInformation = information
            diagnosticActionDetail = "Connected device information updated."
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
        #if SIDECARBRIDGE_APP_STORE_SAFE
        peers.send(ControlMessage(
            .status,
            detail: "remote-input-unavailable-store-build"
        ))
        #else
        peers.send(ControlMessage(
            .status,
            detail: remoteInputAuthorized ? "accessibility-passed" : "accessibility-required"
        ))
        #endif
    }

    private func refreshDevices() {
        reachableSidecarDevices = sidecar.reachableDeviceNames()
    }

    private func attemptNative(preferredName: String?, allowFallback: Bool) {
        attemptID = UUID()
        status = "Displays settings opened"
        detail = "Choose your iPad in Displays. Apple does not provide a public API that lets SidecarBridge start native Sidecar."
        peers.send(ControlMessage(.status, detail: "sidecar-settings-opened"))
        openDisplaysSettings()
    }
}
