import SwiftUI
import UIKit

@MainActor
final class PadConnectionModel: ObservableObject {
    @Published var status = "Looking for your Mac…"
    @Published var detail = "Keep SidecarBridge open on the Mac."
    @Published var frame: UIImage?
    @Published var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var isStreaming = false
    @Published var preferTrackpadControl: Bool = {
        let defaults = UserDefaults.standard
        let key = "preferTrackpadControl"
        guard defaults.object(forKey: key) != nil else {
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }()
    @Published var localNetworkAccess: LocalNetworkAccessState = .checking
    @Published var connectionTransport = "Direct P2P preferred"
    @Published var connectionHealthDetail = "Waiting for encrypted link"
    @Published var connectionLatencyMS: Int?
    @Published var streamAspectRatio: CGFloat = 16.0 / 9.0
    @Published var remoteInputAuthorized = false
    @Published var remoteInputUnavailable = false
    @Published var controlLatencyMS: Int?
    @Published var lastInputAccepted = true
    @Published var remotePointer: CGPoint?
    @Published var pointerIsPressed = false
    @Published var showClickIndicator = false
    @Published var streamFPS = 0
    @Published var isPictureInPicturePossible = false
    @Published var isPictureInPictureActive = false
    @Published var isPictureInPictureSuspended = false
    @Published var keepRunningInBackground: Bool = {
        let defaults = UserDefaults.standard
        let key = "keepRunningInBackground"
        guard defaults.object(forKey: key) != nil else {
            defaults.set(true, forKey: key)
            return true
        }
        return defaults.bool(forKey: key)
    }()
    @Published var backgroundViewerDetail = "Connect and start In-App Display to prepare the background viewer."
    @Published private(set) var discoveryElapsedSeconds = 0
    @Published private(set) var discoveryAttempt = 1
    @Published private(set) var lastDiscoveryIssue: String?
    @Published private(set) var connectedUsingDirectLAN = false
    @Published var fileTransferSnapshot: FileTransferSnapshot?
    @Published var lastReceivedFile: URL?
    @Published var fileTransferError: String?
    @Published var clipboardTransferStatus = "Clipboard transfer ready."
    @Published var pairingCode = ""
    @Published var pairingRequired = false
    @Published var pairingMacName = "Mac"
    @Published var pairingError: String?
    @Published var discoveredMacs: [String] = []
    @Published var selectedMacName = UserDefaults.standard.string(
        forKey: "selectedMacName"
    )
    @Published var localSystemInformation = SystemInformation.current()
    @Published var remoteSystemInformation: SystemInformation?
    @Published var diagnosticActionDetail = "System information is ready."
    @Published var streamDimensions = "Waiting for video"

    let videoDisplay = VideoDisplayController()

    var localNetworkPermissionNeeded: Bool { localNetworkAccess.needsPermission }

    private let peers = PadPeerService()
    private lazy var fileTransfer = FileTransferEngine {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return documents.appendingPathComponent("SidecarBridge Transfers", isDirectory: true)
    }
    private var started = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundRequested = false
    private var backgroundActivationTask: Task<Void, Never>?
    private var inputSequence: UInt64 = 0
    private var inputSentAt: [UInt64: TimeInterval] = [:]
    private var clickFeedbackTask: Task<Void, Never>?
    private var initialFrameRetryTask: Task<Void, Never>?
    private var frameWindowStart = ProcessInfo.processInfo.systemUptime
    private var frameWindowCount = 0
    private var discoveryStartedAt = ProcessInfo.processInfo.systemUptime
    private var discoveryClockTask: Task<Void, Never>?
    private var connectionAttemptedMacName: String?
    // Discovery is passive. This becomes true only after the user taps a Mac
    // row, which keeps the home screen predictable like DeskIn's device list.
    private var userRequestedConnection = false
    private var applicationIsBackgrounded = false
    private var restoreStreamAfterBackground = false
    private var isResumingFromBackground = false
    private var foregroundResumeTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?

    var isDiscoveryTakingLonger: Bool {
        !isConnected && discoveryElapsedSeconds >= 8
    }

    var nearbyDiscoveryIsActive: Bool {
        !isConnected && discoveryElapsedSeconds >= 2 && !localNetworkPermissionNeeded
    }

    var pictureInPictureSupported: Bool {
        videoDisplay.isPictureInPictureSupported
    }

    var backgroundViewerStatus: String {
        if isPictureInPictureActive { return "Active" }
        if !pictureInPictureSupported { return "Not supported on this iPad" }
        if !isStreaming { return "Ready after live video" }
        if isPictureInPicturePossible { return "Available" }
        return "Waiting for system availability"
    }

    init() {
        videoDisplay.onPictureInPictureStateChanged = { [weak self] possible, active, suspended in
            guard let self else { return }
            self.isPictureInPicturePossible = possible
            self.isPictureInPictureActive = active
            self.isPictureInPictureSuspended = suspended
            if active {
                self.backgroundViewerDetail = "Active — the Mac screen can remain visible. Return here to send keyboard and trackpad input."
                self.peers.send(ControlMessage(.status, detail: "viewer-background"))
                self.endBackgroundTask()
            } else if suspended {
                self.backgroundViewerDetail = "Picture in Picture is temporarily suspended by iPadOS."
            } else if possible {
                self.backgroundViewerDetail = self.keepRunningInBackground
                    ? "Ready — PiP can keep the screen visible; return here for keyboard and trackpad control."
                    : "Ready for manual Picture in Picture."
            } else {
                self.backgroundViewerDetail = self.videoDisplay.isPictureInPictureSupported
                    ? self.isStreaming
                        ? "Waiting for iPadOS to make the live viewer available; fast resume remains enabled."
                        : "Ready after the first live video frame."
                    : "Picture in Picture is not supported on this iPad."
            }
            if !active,
               self.isConnected,
               UIApplication.shared.applicationState == .active {
                self.peers.send(ControlMessage(.status, detail: "viewer-foreground"))
            }
            if possible, self.backgroundRequested, !active {
                _ = self.videoDisplay.startPictureInPicture()
            }
        }
        videoDisplay.onPictureInPictureError = { [weak self] message in
            self?.backgroundViewerDetail = message
        }
        videoDisplay.setAutomaticBackgroundStart(keepRunningInBackground)

        peers.onLocalNetworkStateChanged = { [weak self] state in
            guard let self else { return }
            self.localNetworkAccess = state
            if state.needsPermission && !self.isConnected {
                self.status = "Allow Local Network access"
                self.detail = "iPadOS blocked direct discovery. Enable Local Network for SidecarBridge in Settings."
            }
        }

        peers.onConnectionHealthChanged = { [weak self] detail, latency in
            guard let self else { return }
            self.connectionHealthDetail = detail
            self.connectionLatencyMS = latency
            // A foreground return is complete as soon as the encrypted
            // control path answers. Waiting for a video frame here can make a
            // healthy session look like a failed reconnect when the Mac is
            // temporarily between keyframes or the viewer was paused.
            if detail == "Encrypted link healthy",
               self.isConnected,
               self.isResumingFromBackground {
                self.finishForegroundResume()
            }
        }

        peers.onPairingCodeRequired = { [weak self] macName, error in
            guard let self else { return }
            self.isConnecting = false
            self.connectionTimeoutTask?.cancel()
            self.connectionTimeoutTask = nil
            self.pairingRequired = true
            self.pairingMacName = macName
            self.pairingError = error
            self.status = "Enter the Mac pairing code"
            self.detail = "This short-lived 16-digit code mutually authenticates both devices, then creates a Keychain credential."
        }
        peers.onDiscoveredMacsChanged = { [weak self] names in
            guard let self else { return }
            // Keep a remembered Mac visible while Bonjour/AWDL refreshes. A
            // browser can legitimately publish an empty result set for a few
            // seconds after iPadOS resumes or when the access point filters
            // multicast, but the user should still have a concrete device
            // card to tap and retry.
            var visibleNames = names
            if let remembered = self.selectedMacName,
               !visibleNames.contains(remembered) {
                visibleNames.insert(remembered, at: 0)
            }
            self.discoveredMacs = visibleNames
            guard !self.isConnected, !self.pairingRequired else { return }
            // Finding a Mac is not consent to connect. The device remains
            // visible in the list and the user chooses when to establish the
            // encrypted session.
            if !names.isEmpty, !self.userRequestedConnection {
                self.status = "Mac ready to connect"
                self.detail = "Select a Mac below, then tap Connect to start the encrypted session."
                self.connectionHealthDetail = "Waiting for your connection choice"
            }
        }

        peers.onConnectionChanged = { [weak self] connected, peerOrError in
            guard let self else { return }
            self.isConnected = connected
            if connected {
                self.isConnecting = false
                self.connectionTimeoutTask?.cancel()
                self.connectionTimeoutTask = nil
                self.remoteInputUnavailable = false
                self.pairingRequired = false
                self.pairingCode = ""
                self.pairingError = nil
                let isDirectLAN = peerOrError?.hasPrefix("LAN:") == true
                self.connectedUsingDirectLAN = isDirectLAN
                self.lastDiscoveryIssue = nil
                self.stopDiscoveryClock()
                self.connectionTransport = isDirectLAN ? "Direct local link / AWDL" : "Nearby P2P fallback"
                self.status = isDirectLAN ? "Mac found on same Wi-Fi" : "Mac found nearby"
                self.sendDisplayCapabilities()
                self.peers.send(ControlMessage(
                    .status,
                    detail: self.applicationIsBackgrounded
                        ? "viewer-background"
                        : "viewer-foreground"
                ))
                self.exchangeSystemInformation()
                if self.preferTrackpadControl {
                    self.detail = isDirectLAN
                        ? "Direct encrypted local link; requesting the input-capable stream."
                        : "Requesting the input-capable app stream."
                    self.peers.send(ControlMessage(.startFallback))
                } else {
                    self.detail = isDirectLAN
                        ? "Direct local link ready. System Sidecar requires an explicit button press."
                        : "Mac found. Tap Open System Sidecar only if you want to leave this app."
                }
            } else {
                // Network/browser failures can be reported while the selected
                // connection is still being retried. Keep the UI in the
                // explicit Connecting state until the handshake succeeds,
                // pairing is requested, or the user chooses another action.
                if !self.userRequestedConnection {
                    self.isConnecting = false
                    self.connectionTimeoutTask?.cancel()
                    self.connectionTimeoutTask = nil
                }
                if self.applicationIsBackgrounded || self.isResumingFromBackground {
                    self.connectionHealthDetail = self.applicationIsBackgrounded
                        ? "Session suspended — will restore when you return"
                        : "Restoring remembered Mac session"
                    self.connectionLatencyMS = nil
                    self.connectedUsingDirectLAN = false
                    return
                }
                self.connectionHealthDetail = "Recovering connection"
                self.connectionLatencyMS = nil
                self.connectedUsingDirectLAN = false
                self.startDiscoveryClockIfNeeded()
                self.isStreaming = false
                self.remoteInputAuthorized = false
                self.remoteInputUnavailable = false
                self.remotePointer = nil
                self.pointerIsPressed = false
                self.remoteSystemInformation = nil
                self.frame = nil
                self.initialFrameRetryTask?.cancel()
                self.videoDisplay.stopPictureInPicture()
                self.videoDisplay.flush()
                let protocolMismatch = peerOrError?.localizedCaseInsensitiveContains("older insecure connection protocol") == true
                    || peerOrError?.localizedCaseInsensitiveContains("update sidecarbridge") == true
                if protocolMismatch {
                    self.status = "Update SidecarBridge on both devices"
                    self.detail = "The iPad and Mac builds are incompatible. Update the TestFlight iPad app and the Mac app to the same current build."
                    self.lastDiscoveryIssue = self.detail
                } else if let peerOrError, peerOrError.localizedCaseInsensitiveContains("NoAuth") {
                    self.localNetworkAccess = .denied
                    self.status = "Allow Local Network access"
                    self.detail = "iPadOS blocked same-Wi-Fi discovery. Open Settings and enable Local Network for SidecarBridge."
                } else {
                    self.status = "Looking for your Mac…"
                    self.detail = peerOrError ?? "Keep SidecarBridge open on the Mac."
                    if let peerOrError, !peerOrError.isEmpty {
                        self.lastDiscoveryIssue = peerOrError
                    }
                }
                self.connectionTransport = "Searching direct P2P"
                self.fileTransfer.cancelAll(reason: "Connection ended.")
            }
        }
        peers.onCommand = { [weak self] command in self?.handle(command) }
        peers.onFilePacket = { [weak self] transfer in self?.fileTransfer.handle(transfer) }
        peers.onFrame = { [weak self] data in
            guard let self, let image = UIImage(data: data) else { return }
            self.finishForegroundResume()
            self.updateStreamPresentation(
                width: Int(image.size.width),
                height: Int(image.size.height),
                format: "JPEG",
                detail: "Using the SidecarBridge fallback stream."
            )
            _ = self.videoDisplay.enqueueJPEG(image)
            self.frame = image
        }
        peers.onVideoFrame = { [weak self] frame in
            guard let self else { return }
            self.finishForegroundResume()
            if self.frame != nil { self.frame = nil }
            self.updateStreamPresentation(
                width: frame.width,
                height: frame.height,
                format: "H.264",
                detail: "Hardware-decoded H.264 HiDPI stream."
            )
            let displayed = self.videoDisplay.enqueue(frame)
            if displayed { self.recordVideoFrame() }
            if !displayed, frame.isKeyFrame {
                self.retryInitialKeyFrameAfterDisplayAppears(frame)
            }
        }
        configureFileTransfer()
    }

    var isFileTransferring: Bool { fileTransfer.isBusy }

    /// Selects a discovered Mac without opening a connection. The UI uses
    /// this as the device-list step; connecting is a separate explicit action.
    func chooseMac(_ name: String) {
        // Cancel any stale dial from an earlier session before showing this
        // device as selected. Choosing a card must remain a presentation-only
        // action; Connect is the only method that may set the dial gate.
        if !isConnected {
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            isConnecting = false
            peers.clearMacSelection()
        }
        selectedMacName = name
        UserDefaults.standard.set(name, forKey: "selectedMacName")
        userRequestedConnection = false
        pairingRequired = false
        pairingCode = ""
        pairingError = nil
        status = "Ready to connect"
        detail = "Tap Connect to start the encrypted session with \(name)."
        connectionHealthDetail = "Waiting for your connection choice"
    }

    func connectSelectedMac() {
        guard let selectedMacName else {
            status = "Choose a Mac first"
            detail = "Select a device card before connecting."
            return
        }
        userRequestedConnection = true
        isConnecting = true
        armConnectionTimeout()
        connect(
            to: selectedMacName,
            detail: "Establishing an encrypted local session."
        )
    }

    /// Compatibility entry point for older callers: selecting a Mac from a
    /// direct-connect action still means the user explicitly requested a
    /// connection.
    func selectMac(_ name: String) {
        chooseMac(name)
        connectSelectedMac()
    }

    private func connect(to name: String, detail connectionDetail: String) {
        selectedMacName = name
        connectionAttemptedMacName = name
        UserDefaults.standard.set(name, forKey: "selectedMacName")
        pairingRequired = false
        pairingCode = ""
        pairingError = nil
        status = "Connecting to \(name)…"
        detail = connectionDetail
        peers.selectMac(named: name)
    }

    private func armConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.isConnecting, !self.isConnected else { return }
            self.isConnecting = false
            self.status = "Ready to retry connection"
            self.detail = "The selected Mac is still visible. Tap Connect to try the direct and nearby paths again."
            self.connectionHealthDetail = "Waiting for another connection attempt"
            // Clear the stale dial underneath the visible device card. The
            // next explicit Connect action starts a fresh LAN/P2P attempt;
            // this prevents an endless loading state when a route is blocked.
            self.userRequestedConnection = false
            self.peers.clearMacSelection()
            self.connectionTimeoutTask = nil
        }
    }

    func sendFile(at url: URL) {
        guard isConnected else {
            fileTransferError = "Connect the Mac before sending a file."
            return
        }
        fileTransferError = nil
        fileTransfer.sendFile(at: url)
    }

    func submitPairingCode() {
        let normalized = PairingCode.normalize(pairingCode)
        guard normalized.count == PairingCode.characterCount else {
            pairingError = "Enter all 16 digits shown in the Mac app."
            return
        }
        pairingError = nil
        detail = "Verifying the one-time code over the encrypted local link…"
        peers.submitPairingCode(normalized)
    }

    func forgetTrustedMacs() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        isConnecting = false
        SecureCredentialStore.removeAll(accountPrefix: "pad.mac.")
        UserDefaults.standard.removeObject(forKey: "selectedMacName")
        UserDefaults.standard.removeObject(forKey: "lastDirectMacHost")
        selectedMacName = nil
        connectionAttemptedMacName = nil
        userRequestedConnection = false
        pairingRequired = false
        pairingCode = ""
        pairingError = nil
        isConnected = false
        connectedUsingDirectLAN = false
        status = "Trusted Macs forgotten"
        detail = "Select a Mac and enter its current 16-digit pairing code."
        peers.restart()
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
        beginDiscoveryClock(incrementAttempt: false)
        peers.start()
        if let rememberedMac = selectedMacName {
            if !discoveredMacs.contains(rememberedMac) {
                discoveredMacs = [rememberedMac]
            }
            status = "Choose a Mac to connect"
            detail = "Remembered Mac: \(rememberedMac). Tap Connect when you are ready."
        }
    }

    func retry() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        isConnecting = false
        status = "Looking for your Mac…"
        detail = "Restarting direct local-network, AWDL, and nearby discovery."
        lastDiscoveryIssue = nil
        if !isConnected {
            userRequestedConnection = false
            connectionAttemptedMacName = nil
            peers.clearMacSelection()
        }
        beginDiscoveryClock(incrementAttempt: true)
        peers.restart()
    }

    func refreshSystemInformation() {
        localSystemInformation = SystemInformation.current()
        diagnosticActionDetail = isConnected
            ? "Refreshed this device and requested the connected Mac."
            : "Refreshed this device. Connect a Mac to see both devices."
        exchangeSystemInformation()
    }

    func copyDiagnosticReport() {
        UIPasteboard.general.string = diagnosticReport
        diagnosticActionDetail = "Privacy-safe diagnostic report copied."
    }

    var diagnosticReport: String {
        DiagnosticReportBuilder.make(
            local: localSystemInformation,
            remote: remoteSystemInformation,
            connection: [
                DiagnosticField("Status", status),
                DiagnosticField("Transport", connectionTransport),
                DiagnosticField("Encrypted Mac", isConnected ? "Connected" : "Not connected"),
                DiagnosticField("Streaming", isStreaming ? "Active" : "Inactive"),
                DiagnosticField("Stream", streamDimensions),
                DiagnosticField("Displayed frame rate", streamFPS > 0 ? "\(streamFPS) FPS" : "Not measured"),
                DiagnosticField(
                    "Connection latency",
                    connectionLatencyMS.map { "\($0) ms" } ?? "Not measured"
                ),
                DiagnosticField(
                    "Input latency",
                    controlLatencyMS.map { "\($0) ms" } ?? "Not measured"
                ),
                DiagnosticField("Link health", connectionHealthDetail),
                DiagnosticField(
                    "Local Network permission",
                    localNetworkAccess.isGranted ? "Passed" : localNetworkPermissionNeeded ? "Required" : "Checking"
                ),
                DiagnosticField(
                    "Mac Accessibility permission",
                    remoteInputAuthorized ? "Passed" : "Required or unknown"
                ),
                DiagnosticField(
                    "Background viewer",
                    backgroundViewerStatus
                )
            ]
        )
    }

    private func exchangeSystemInformation() {
        guard isConnected else { return }
        if let message = ControlMessage.systemInformation(localSystemInformation) {
            peers.send(message)
        }
        peers.send(.requestSystemInformation)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let shouldRestoreStream = restoreStreamAfterBackground
            applicationIsBackgrounded = false
            // A foreground transition owns the sample-buffer layer again, so
            // cancel any pending PiP retry before stopping PiP. The separate
            // restore flags below keep the encrypted session alive until the
            // first fresh frame arrives.
            backgroundRequested = false
            backgroundActivationTask?.cancel()
            backgroundActivationTask = nil
            backgroundViewerDetail = shouldRestoreStream
                ? "Returning to SidecarBridge — restoring the encrypted session…"
                : "Ready — PiP can keep the screen visible; return here for keyboard and trackpad control."
            if isPictureInPictureActive { videoDisplay.stopPictureInPicture() }
            if shouldRestoreStream {
                beginForegroundResumePresentation()
            }
            // Returning to the foreground may restore a session the user
            // already started, but the initial active transition must never
            // dial a remembered Mac just because the Remote Control tab is
            // visible. Discovery publishes cards; Connect is explicit.
            if started, userRequestedConnection || restoreStreamAfterBackground || isStreaming {
                if userRequestedConnection, !isConnected { isConnecting = true }
                peers.resumeAfterBackground()
            }
            if isConnected {
                peers.send(ControlMessage(.status, detail: "viewer-foreground"))
            }
            endBackgroundTask()
        case .background:
            beginBackgroundTransition()
        case .inactive:
            beginBackgroundTransition()
        @unknown default:
            break
        }
    }

    /// Called by UIApplication.willResignActiveNotification as an early
    /// lifecycle hook. SwiftUI's `.inactive` phase can be delivered only after
    /// iPadOS has started the suspension transition, which is too late for a
    /// reliable automatic PiP handoff on some iPadOS versions.
    func appWillResignActive() {
        beginBackgroundTransition()
    }

    private func beginBackgroundTransition() {
        prepareConnectionForBackgroundIfNeeded()
        guard isStreaming, keepRunningInBackground else {
            backgroundViewerDetail = isStreaming
                ? "Automatic background viewing is off. Return here to keep controlling the Mac."
                : "Connect to a Mac first; the background viewer will be ready after the first frame."
            return
        }

        // The notification and scene-phase callbacks can both arrive for one
        // app switch. Keep one PiP request and one short background grace task;
        // repeating them makes AVKit race its own transition.
        guard !backgroundRequested else { return }
        backgroundRequested = true
        beginBackgroundGracePeriod()
        backgroundViewerDetail = isPictureInPicturePossible
            ? "Starting Picture in Picture…"
            : "Preparing the background viewer; preserving the session for fast resume."
        _ = videoDisplay.startPictureInPicture()
        verifyBackgroundActivation()
    }

    private func prepareConnectionForBackgroundIfNeeded() {
        guard !applicationIsBackgrounded else { return }
        applicationIsBackgrounded = true
        restoreStreamAfterBackground = isStreaming
        if isConnected {
            peers.send(ControlMessage(.status, detail: "viewer-background"))
        }
        peers.prepareForBackground()
    }

    private func beginForegroundResumePresentation() {
        isResumingFromBackground = true
        status = "Resuming Mac screen…"
        detail = "Restoring the remembered encrypted session."
        connectionHealthDetail = "Fast resume in progress"
        foregroundResumeTask?.cancel()
        foregroundResumeTask = Task { [weak self] in
            // A Wi-Fi-to-AWDL transition can outlast the scene animation.
            // Keep the selected session in the resume state long enough for
            // both peer watchdogs to finish their coordinated grace period.
            try? await Task.sleep(for: .seconds(18))
            guard !Task.isCancelled,
                  let self,
                  self.isResumingFromBackground else { return }
            self.isResumingFromBackground = false
            self.restoreStreamAfterBackground = false
            self.backgroundRequested = false
            self.backgroundViewerDetail = "The saved session did not resume; discovery is continuing automatically."
            self.status = "Looking for your Mac…"
            self.detail = "The saved session did not resume; discovery is continuing automatically."
            self.startDiscoveryClockIfNeeded()
        }
    }

    private func finishForegroundResume() {
        guard !applicationIsBackgrounded,
              isResumingFromBackground || restoreStreamAfterBackground else { return }
        foregroundResumeTask?.cancel()
        foregroundResumeTask = nil
        isResumingFromBackground = false
        restoreStreamAfterBackground = false
        backgroundRequested = false
        backgroundViewerDetail = keepRunningInBackground
            ? "Ready — PiP can keep the screen visible; return here for keyboard and trackpad control."
            : "Automatic background viewing is off."
        connectionHealthDetail = "Encrypted link resumed"
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func requestFallback() {
        peers.send(ControlMessage(.startFallback))
        status = "Requesting app stream…"
        detail = "Approve Screen Recording on the Mac if asked."
    }

    func requestSystemSidecar() {
        guard isConnected else { return }
        status = "Requesting System Sidecar…"
        detail = "Apple's Sidecar app will replace this app while the native session is active."
        peers.send(ControlMessage(.trySidecar, detail: UIDevice.current.name))
    }

    func setPreferTrackpadControl(_ enabled: Bool) {
        preferTrackpadControl = enabled
        UserDefaults.standard.set(enabled, forKey: "preferTrackpadControl")
        guard isConnected else { return }
        if enabled {
            requestFallback()
        } else {
            status = "System Sidecar selected"
            detail = "It will not launch automatically. Tap Open System Sidecar when you want Apple's separate display session."
        }
    }

    func stopStreaming() {
        peers.send(ControlMessage(.stopFallback))
        frame = nil
        videoDisplay.stopPictureInPicture()
        backgroundRequested = false
        backgroundActivationTask?.cancel()
        videoDisplay.flush()
        isStreaming = false
        remotePointer = nil
        pointerIsPressed = false
        showClickIndicator = false
        status = "App stream paused"
        detail = "Choose App Stream to reconnect."
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func togglePictureInPicture() {
        guard isStreaming else { return }
        backgroundRequested = !isPictureInPictureActive
        videoDisplay.togglePictureInPicture()
    }

    func setKeepRunningInBackground(_ enabled: Bool) {
        keepRunningInBackground = enabled
        UserDefaults.standard.set(enabled, forKey: "keepRunningInBackground")
        videoDisplay.setAutomaticBackgroundStart(enabled)
        if enabled {
            if !pictureInPictureSupported {
                backgroundViewerDetail = "Picture in Picture is not supported on this iPad."
            } else if isStreaming && isPictureInPicturePossible {
                backgroundViewerDetail = "Ready — PiP can keep the screen visible; return here for keyboard and trackpad control."
            } else if isStreaming {
                backgroundViewerDetail = "Waiting for iPadOS to make the live viewer available; fast resume is enabled meanwhile."
            } else {
                backgroundViewerDetail = "Ready after the first live video frame."
            }
        } else {
            backgroundRequested = false
            backgroundViewerDetail = "Automatic background viewing is off."
            if isPictureInPictureActive { videoDisplay.stopPictureInPicture() }
        }
    }

    func sendInput(_ input: RemoteInputEvent) {
        guard isStreaming, !remoteInputUnavailable else { return }
        updatePointerFeedback(for: input)
        inputSequence &+= 1
        var sequenced = input
        sequenced.sequence = inputSequence
        if sequenced.shouldAcknowledge {
            inputSentAt[inputSequence] = ProcessInfo.processInfo.systemUptime
        }
        if inputSentAt.count > 40 {
            inputSentAt = inputSentAt.filter { inputSequence &- $0.key < 36 }
        }
        peers.sendInput(sequenced)
    }

    func sendLeftClick() {
        sendInput(.click())
    }

    func sendDoubleClick() {
        sendInput(.doubleClick())
    }

    func sendRightClick() {
        sendInput(.click(secondary: true))
    }

    func requestMacClipboard() {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before requesting its clipboard."
            return
        }
        clipboardTransferStatus = "Requesting the Mac clipboard…"
        peers.send(ControlMessage(.requestClipboard))
    }

    func sendClipboardToMac() {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before sending clipboard text."
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            clipboardTransferStatus = "The iPad clipboard has no text to send."
            return
        }
        let prepared = ClipboardTransfer.prepare(text)
        peers.send(.clipboardText(prepared))
        clipboardTransferStatus = prepared == text
            ? "iPad clipboard sent to Mac."
            : "iPad clipboard sent (truncated to 48 KB)."
    }

    private func updatePointerFeedback(for input: RemoteInputEvent) {
        if let x = input.x, let y = input.y {
            remotePointer = CGPoint(
                x: min(max(x, 0), 1),
                y: min(max(y, 0), 1)
            )
        } else if input.kind == .pointerDelta,
                  let deltaX = input.deltaX,
                  let deltaY = input.deltaY {
            let current = remotePointer ?? CGPoint(x: 0.5, y: 0.5)
            remotePointer = CGPoint(
                x: min(max(current.x + deltaX, 0), 1),
                y: min(max(current.y + deltaY, 0), 1)
            )
        }

        switch input.kind {
        case .primaryDown:
            pointerIsPressed = true
            showClickIndicator = true
        case .primaryDrag:
            pointerIsPressed = true
        case .primaryUp:
            pointerIsPressed = false
            flashClickIndicator()
        case .primaryClick, .primaryDoubleClick, .secondaryClick, .secondaryDoubleClick:
            flashClickIndicator()
        case .releaseButtons:
            pointerIsPressed = false
        default:
            break
        }
    }

    private func recordVideoFrame() {
        frameWindowCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        let duration = now - frameWindowStart
        guard duration >= 0.5 else { return }
        streamFPS = Int((Double(frameWindowCount) / duration).rounded())
        frameWindowCount = 0
        frameWindowStart = now
    }

    /// Publishes stream metadata only when it changes. H.264 frames arrive on
    /// the main actor because AVSampleBufferDisplayLayer is main-thread bound;
    /// re-publishing the same status, dimensions, and idle-timer state for
    /// every frame made SwiftUI do needless work at 30–40 FPS.
    private func updateStreamPresentation(
        width: Int,
        height: Int,
        format: String,
        detail streamDetail: String
    ) {
        let safeWidth = max(width, 1)
        let safeHeight = max(height, 1)
        let ratio = CGFloat(safeWidth) / CGFloat(safeHeight)
        if abs(streamAspectRatio - ratio) > 0.0001 {
            streamAspectRatio = ratio
        }
        let dimensions = "\(safeWidth) × \(safeHeight) \(format)"
        if streamDimensions != dimensions {
            streamDimensions = dimensions
        }
        guard !isStreaming else { return }
        isStreaming = true
        status = "Mac screen"
        detail = streamDetail
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func retryInitialKeyFrameAfterDisplayAppears(_ frame: VideoFrame) {
        initialFrameRetryTask?.cancel()
        initialFrameRetryTask = Task { [weak self] in
            // isStreaming changes the SwiftUI hierarchy and creates the
            // AVSampleBufferDisplayLayer. Retry the same keyframe after that
            // render pass instead of making the sender wait for a timeout.
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.isStreaming else { return }
                if self.videoDisplay.enqueue(frame) {
                    self.recordVideoFrame()
                    return
                }
            }
        }
    }

    private func flashClickIndicator() {
        clickFeedbackTask?.cancel()
        showClickIndicator = true
        clickFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.showClickIndicator = false
        }
    }

    private func sendDisplayCapabilities() {
        let nativeBounds = UIScreen.main.nativeBounds
        let nativeWidth = Int(max(nativeBounds.width, nativeBounds.height))
        peers.send(ControlMessage(.hello, detail: "display-width:\(nativeWidth)"))
    }

    private func startDiscoveryClockIfNeeded() {
        guard discoveryClockTask == nil else { return }
        beginDiscoveryClock(incrementAttempt: false)
    }

    private func beginDiscoveryClock(incrementAttempt: Bool) {
        discoveryClockTask?.cancel()
        if incrementAttempt { discoveryAttempt += 1 }
        discoveryStartedAt = ProcessInfo.processInfo.systemUptime
        discoveryElapsedSeconds = 0
        discoveryClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.isConnected else { return }
                self.discoveryElapsedSeconds = max(
                    0,
                    Int(ProcessInfo.processInfo.systemUptime - self.discoveryStartedAt)
                )
            }
        }
    }

    private func stopDiscoveryClock() {
        discoveryClockTask?.cancel()
        discoveryClockTask = nil
    }

    private func beginBackgroundGracePeriod() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SidecarBridge connection") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func verifyBackgroundActivation() {
        backgroundActivationTask?.cancel()
        backgroundActivationTask = Task { [weak self] in
            for attempt in 1...5 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.backgroundRequested else { return }
                if self.isPictureInPictureActive { return }
                if self.isPictureInPicturePossible {
                    self.backgroundViewerDetail = "Background viewer retry \(attempt) of 5…"
                    _ = self.videoDisplay.startPictureInPicture()
                }
            }
            guard !Task.isCancelled, let self, self.backgroundRequested, !self.isPictureInPictureActive else { return }
            self.backgroundViewerDetail = self.isPictureInPicturePossible
                ? "iPadOS did not start Picture in Picture. Return here and tap Start PiP Now."
                : "Picture in Picture is unavailable; iPadOS will suspend the stream after its short grace period."
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func handle(_ command: ControlMessage) {
        if command.kind == .requestSystemInformation {
            localSystemInformation = SystemInformation.current()
            if let message = ControlMessage.systemInformation(localSystemInformation) {
                peers.send(message)
            }
            return
        }
        if command.kind == .systemInformation {
            guard let information = command.systemInformationPayload else { return }
            remoteSystemInformation = information
            diagnosticActionDetail = "Connected Mac information updated."
            return
        }
        if command.kind == .requestClipboard {
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                peers.send(ControlMessage(.clipboardError, detail: "The iPad clipboard has no text."))
                return
            }
            peers.send(.clipboardText(text))
            return
        }
        if command.kind == .clipboardText {
            guard let text = command.clipboardTextPayload else {
                clipboardTransferStatus = "The received clipboard text was invalid or too large."
                return
            }
            UIPasteboard.general.string = text
            clipboardTransferStatus = "Copied Mac clipboard to the iPad."
            return
        }
        if command.kind == .clipboardError {
            clipboardTransferStatus = command.detail ?? "Clipboard transfer failed."
            return
        }
        guard command.kind == .status, let value = command.detail else { return }
        switch value {
        case "sidecar-wired":
            status = "Trying wired Sidecar…"
            detail = "The Mac detected an iPad USB connection."
        case "sidecar-wireless":
            status = "Trying wireless Sidecar…"
            detail = "Using Apple Continuity discovery."
        case "sidecar-unavailable", "sidecar-failed":
            status = "Native Sidecar unavailable"
            detail = "The Mac is starting the app stream."
        case "fallback-active":
            status = "App stream connected"
            detail = "Waiting for the first frame."
        case "sidecar-connected":
            status = "System Sidecar connected"
            detail = "iPadOS is switching to Apple's separate Sidecar display app."
        case "accessibility-required":
            remoteInputUnavailable = false
            remoteInputAuthorized = false
            status = "Allow remote input on the Mac"
            detail = "Enable SidecarBridge under Privacy & Security → Accessibility. Video can continue meanwhile."
        case "accessibility-passed":
            remoteInputUnavailable = false
            remoteInputAuthorized = true
            if isStreaming {
                status = "Mac screen"
                detail = "Hardware-decoded H.264 HiDPI stream with remote input."
            }
        case "remote-input-unavailable-store-build":
            remoteInputUnavailable = true
            remoteInputAuthorized = false
            lastInputAccepted = false
            status = "Remote input unavailable"
            detail = "Enable SidecarBridge under macOS Privacy & Security → Accessibility, then reconnect."
        default:
            if value.hasPrefix("pointer-position:") {
                let parts = value.split(separator: ":")
                if parts.count >= 3,
                   let x = Double(parts[1]),
                   let y = Double(parts[2]) {
                    remotePointer = CGPoint(
                        x: min(max(x, 0), 1),
                        y: min(max(y, 0), 1)
                    )
                }
            } else if value.hasPrefix("input-ack:") {
                let parts = value.split(separator: ":")
                guard parts.count >= 3, let sequence = UInt64(parts[1]) else { return }
                if let sentAt = inputSentAt.removeValue(forKey: sequence) {
                    controlLatencyMS = max(0, Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1_000))
                }
                lastInputAccepted = parts[2] == "1"
                remoteInputAuthorized = lastInputAccepted
                if parts.count >= 5,
                   let x = Double(parts[3]),
                   let y = Double(parts[4]) {
                    remotePointer = CGPoint(
                        x: min(max(x, 0), 1),
                        y: min(max(y, 0), 1)
                    )
                }
            } else if value.hasPrefix("fallback-error:") {
                status = "Mac permission required"
                detail = String(value.dropFirst("fallback-error:".count))
            }
        }
    }
}
