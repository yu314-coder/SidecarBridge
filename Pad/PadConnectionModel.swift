import SwiftUI
import UIKit

@MainActor
final class PadConnectionModel: ObservableObject {
    @Published var status = "Looking for your Mac…"
    @Published var detail = "Keep SidecarBridge open on the Mac."
    @Published var frame: UIImage?
    @Published var isConnected = false
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
    @Published var backgroundViewerDetail = "Automatic background viewer is ready."
    @Published private(set) var discoveryElapsedSeconds = 0
    @Published private(set) var discoveryAttempt = 1
    @Published private(set) var lastDiscoveryIssue: String?
    @Published private(set) var connectedUsingDirectLAN = false
    @Published var fileTransferSnapshot: FileTransferSnapshot?
    @Published var lastReceivedFile: URL?
    @Published var fileTransferError: String?
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
    private var applicationIsBackgrounded = false
    private var restoreStreamAfterBackground = false
    private var isResumingFromBackground = false
    private var foregroundResumeTask: Task<Void, Never>?

    var isDiscoveryTakingLonger: Bool {
        !isConnected && discoveryElapsedSeconds >= 8
    }

    var nearbyDiscoveryIsActive: Bool {
        !isConnected && discoveryElapsedSeconds >= 2 && !localNetworkPermissionNeeded
    }

    init() {
        videoDisplay.onPictureInPictureStateChanged = { [weak self] possible, active, suspended in
            guard let self else { return }
            self.isPictureInPicturePossible = possible
            self.isPictureInPictureActive = active
            self.isPictureInPictureSuspended = suspended
            if active {
                self.backgroundViewerDetail = "Active — the stream can continue behind other apps."
                self.peers.send(ControlMessage(.status, detail: "viewer-background"))
                self.endBackgroundTask()
            } else if suspended {
                self.backgroundViewerDetail = "Picture in Picture is temporarily suspended by iPadOS."
            } else if possible {
                self.backgroundViewerDetail = self.keepRunningInBackground
                    ? "Ready — switching apps starts Picture in Picture automatically."
                    : "Ready for manual Picture in Picture."
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
            self?.connectionHealthDetail = detail
            self?.connectionLatencyMS = latency
        }

        peers.onPairingCodeRequired = { [weak self] macName, error in
            guard let self else { return }
            self.pairingRequired = true
            self.pairingMacName = macName
            self.pairingError = error
            self.status = "Enter the Mac pairing code"
            self.detail = "This short-lived 16-character code mutually authenticates both devices, then creates a Keychain credential."
        }
        peers.onDiscoveredMacsChanged = { [weak self] names in
            guard let self else { return }
            self.discoveredMacs = names
            guard !self.isConnected, !self.pairingRequired else { return }

            let preferredMac: String?
            if let selectedMacName = self.selectedMacName {
                preferredMac = names.contains(selectedMacName)
                    ? selectedMacName
                    : nil
            } else {
                // The first launch still chooses automatically when there is
                // only one Mac. Authentication remains protected by the
                // one-time pairing code and Keychain credential.
                preferredMac = names.count == 1 ? names[0] : nil
            }

            guard let preferredMac,
                  self.connectionAttemptedMacName != preferredMac else { return }
            self.connect(
                to: preferredMac,
                detail: self.selectedMacName == nil
                    ? "One Mac found; establishing an encrypted local session."
                    : "Reconnecting to your remembered trusted Mac."
            )
        }

        peers.onConnectionChanged = { [weak self] connected, peerOrError in
            guard let self else { return }
            self.isConnected = connected
            if connected {
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
            self.frame = image
            self.streamAspectRatio = image.size.width / max(image.size.height, 1)
            self.streamDimensions = "\(Int(image.size.width)) × \(Int(image.size.height)) JPEG"
            self.isStreaming = true
            self.status = "Mac screen"
            self.detail = "Using the SidecarBridge fallback stream."
            UIApplication.shared.isIdleTimerDisabled = true
        }
        peers.onVideoFrame = { [weak self] frame in
            guard let self else { return }
            self.finishForegroundResume()
            self.frame = nil
            self.streamAspectRatio = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
            self.streamDimensions = "\(frame.width) × \(frame.height) H.264"
            let displayed = self.videoDisplay.enqueue(frame)
            if displayed { self.recordVideoFrame() }
            self.isStreaming = true
            self.status = "Mac screen"
            self.detail = "Hardware-decoded H.264 HiDPI stream."
            UIApplication.shared.isIdleTimerDisabled = true
            if !displayed, frame.isKeyFrame {
                self.retryInitialKeyFrameAfterDisplayAppears(frame)
            }
        }
        configureFileTransfer()
    }

    var isFileTransferring: Bool { fileTransfer.isBusy }

    func selectMac(_ name: String) {
        connect(
            to: name,
            detail: "Establishing an encrypted local session."
        )
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
            pairingError = "Enter all 16 characters shown in the Mac app."
            return
        }
        pairingError = nil
        detail = "Verifying the one-time code over the encrypted local link…"
        peers.submitPairingCode(normalized)
    }

    func forgetTrustedMacs() {
        SecureCredentialStore.removeAll(accountPrefix: "pad.mac.")
        UserDefaults.standard.removeObject(forKey: "selectedMacName")
        UserDefaults.standard.removeObject(forKey: "lastDirectMacHost")
        selectedMacName = nil
        connectionAttemptedMacName = nil
        pairingRequired = false
        pairingCode = ""
        pairingError = nil
        isConnected = false
        connectedUsingDirectLAN = false
        status = "Trusted Macs forgotten"
        detail = "Select a Mac and enter its current 16-character pairing code."
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
    }

    func retry() {
        status = "Looking for your Mac…"
        detail = "Restarting direct local-network, AWDL, and nearby discovery."
        lastDiscoveryIssue = nil
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
                    isPictureInPictureActive ? "Active" : isPictureInPicturePossible ? "Available" : "Unavailable"
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
            backgroundRequested = false
            backgroundActivationTask?.cancel()
            backgroundActivationTask = nil
            if isPictureInPictureActive { videoDisplay.stopPictureInPicture() }
            if shouldRestoreStream {
                beginForegroundResumePresentation()
            }
            if started { peers.resumeAfterBackground() }
            if isConnected {
                peers.send(ControlMessage(.status, detail: "viewer-foreground"))
            }
            endBackgroundTask()
        case .background:
            prepareConnectionForBackgroundIfNeeded()
            guard isStreaming, keepRunningInBackground else { return }
            backgroundRequested = true
            if !isPictureInPictureActive {
                beginBackgroundGracePeriod()
                backgroundViewerDetail = "Completing background viewer start…"
                _ = videoDisplay.startPictureInPicture()
                verifyBackgroundActivation()
            } else {
                endBackgroundTask()
            }
        case .inactive:
            prepareConnectionForBackgroundIfNeeded()
            guard isStreaming, keepRunningInBackground else { return }
            backgroundRequested = true
            beginBackgroundGracePeriod()
            // PiP needs to start while SidecarBridge is still transitioning out
            // of the foreground. Waiting for `.background` is too late on some
            // iPadOS releases and leaves only the short background grace task.
            backgroundViewerDetail = "Starting Picture in Picture…"
            _ = videoDisplay.startPictureInPicture()
            verifyBackgroundActivation()
        @unknown default:
            break
        }
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
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  let self,
                  self.isResumingFromBackground else { return }
            self.isResumingFromBackground = false
            self.restoreStreamAfterBackground = false
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
            backgroundViewerDetail = isPictureInPicturePossible
                ? "Ready — switching apps starts Picture in Picture automatically."
                : "Waiting for the live video before background viewing is available."
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
            status = "Viewer-only Mac companion"
            detail = "This Mac App Store edition does not provide remote keyboard or trackpad input. Install the direct companion build for full control."
        default:
            if value.hasPrefix("input-ack:") {
                let parts = value.split(separator: ":")
                guard parts.count == 3, let sequence = UInt64(parts[1]) else { return }
                if let sentAt = inputSentAt.removeValue(forKey: sequence) {
                    controlLatencyMS = max(0, Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1_000))
                }
                lastInputAccepted = parts[2] == "1"
                remoteInputAuthorized = lastInputAccepted
            } else if value.hasPrefix("fallback-error:") {
                status = "Mac permission required"
                detail = String(value.dropFirst("fallback-error:".count))
            }
        }
    }
}
