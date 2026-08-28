import SwiftUI
import UIKit

@MainActor
final class PadConnectionModel: ObservableObject {
    struct ReceivedFile: Identifiable, Equatable {
        let url: URL
        let size: Int64
        let modifiedAt: Date?

        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// A single pasteboard read. iPadOS can present its paste privacy alert
    /// when an app reads the general pasteboard, so callers must not read the
    /// same change once for its signature and again to transmit it.
    private struct ClipboardPayload {
        let files: [URL]
        let text: String?

        var signature: String? {
            if !files.isEmpty {
                return ClipboardTransfer.fileSignature(files)
            }
            guard let text, !text.isEmpty else { return nil }
            return "text:\(text)"
        }
    }

    @Published var status = "Ready to connect"
    @Published var detail = "Choose a Mac card or enter its 16-digit pairing code below."
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
    @Published var streamResolution: StreamResolutionPreference = {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: StreamPreferenceStore.resolutionKey)
            .flatMap(StreamResolutionPreference.init(rawValue:))
            ?? StreamPreferences.defaults.resolution
    }()
    @Published var streamFrameRate: StreamFrameRatePreference = {
        let storedFrameRate = StreamPreferenceStore.loadFrameRate()
        return StreamPreferenceStore.loadUltraMode()
            || storedFrameRate.rawValue <= StreamCadencePolicy.nearbyFrameRateCeiling
            ? storedFrameRate
            : .fps120
    }()
    /// Developer-only performance override. This is sent to the Mac with the
    /// stream profile so the sender, rather than only the iPad picker, raises
    /// its capture and encoder ceilings together.
    @Published var ultraModeEnabled: Bool = {
        StreamPreferenceStore.loadUltraMode()
    }()
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
    @Published private(set) var receivedFiles: [ReceivedFile] = []
    @Published var fileTransferError: String?
    @Published var queuedFileCount = 0
    @Published var clipboardTransferStatus = "Clipboard transfer ready."
    @Published var automaticClipboardSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticClipboardSyncEnabled, forKey: Self.automaticClipboardSyncDefaultsKey)
            if automaticClipboardSyncEnabled {
                startClipboardMonitoring()
            } else {
                stopClipboardMonitoring()
            }
        }
    }
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
        return documents.appendingPathComponent(Self.transferDirectoryName, isDirectory: true)
    }
    private static let transferDirectoryName = "SidecarBridge Transfers"

    /// Received files live in the app's Documents directory, which is exposed
    /// to the Files app by UIFileSharingEnabled. Keep the exact path visible so
    /// a user can find every received file, not only the most recent ShareLink.
    var receivedFilesLocationDescription: String {
        "Files > On My iPad > SidecarBridge > \(Self.transferDirectoryName)"
    }

    private var transferDirectoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.transferDirectoryName, isDirectory: true)
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
    private var presentedStreamWidth = 0
    private var presentedStreamHeight = 0
    private var presentedStreamFormat = ""
    private var discoveryStartedAt = ProcessInfo.processInfo.systemUptime
    private var discoveryClockTask: Task<Void, Never>?
    private var connectionAttemptedMacName: String?
    // Discovery is passive. This becomes true only after the user taps a Mac
    // row, which keeps the home screen predictable like DeskIn's device list.
    private var userRequestedConnection = false
    private var applicationIsBackgrounded = false
    private var restoreStreamAfterBackground = false
    private var enteredBackground = false
    private var isResumingFromBackground = false
    private var foregroundResumeTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var pendingFileURLs: [URL] = []
    private var lastObservedClipboardChangeCount: Int?
    private var lastObservedClipboardSignature: String?
    private var suppressedClipboardSignature: String?
    private var automaticReceivedFileURLs: [URL] = []
    private var clipboardMonitorTask: Task<Void, Never>?
    private var clipboardChangeObserver: NSObjectProtocol?
    // Clipboard reads on iPadOS can display the system paste privacy alert and
    // briefly take focus away from the live viewer.  Keep automatic sync as an
    // explicit opt-in, with a new key so upgrades do not inherit the old
    // always-on default.
    private static let automaticClipboardSyncDefaultsKey = "automaticClipboardSyncEnabled.v2"

    /// iPadOS may present its paste privacy alert when a foreground app reads
    /// data from the general pasteboard.  Keep the connection and PiP viewer
    /// alive in the background, but defer content reads until the scene is
    /// active again.  This avoids repeatedly asking while the user is using a
    /// different app or while a system transition is in progress.
    private var canReadSystemPasteboard: Bool {
        UIApplication.shared.applicationState == .active
    }

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
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.automaticClipboardSyncDefaultsKey) == nil {
            defaults.set(false, forKey: Self.automaticClipboardSyncDefaultsKey)
        }
        automaticClipboardSyncEnabled = defaults.bool(forKey: Self.automaticClipboardSyncDefaultsKey)
        // Do not touch the general pasteboard during launch.  The first read
        // is performed only by an explicit clipboard action or after the user
        // opts into automatic sync.
        lastObservedClipboardChangeCount = nil
        lastObservedClipboardSignature = nil
        startClipboardMonitoring()
        videoDisplay.onKeyFrameNeeded = { [weak self] in
            guard let self, self.isConnected else { return }
            // A decoder gap is recoverable without reconnecting the session.
            // Ask the Mac for an IDR frame over the already-authenticated
            // control channel and keep the live viewer at its cadence floor.
            self.peers.send(ControlMessage(.status, detail: "video-keyframe-needed"))
        }
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
            let hadLiveVideoSession = self.isStreaming
                || self.frame != nil
                || self.videoDisplay.hasPictureInPictureContent
            self.isConnected = connected
            if connected {
                if hadLiveVideoSession {
                    // An explicit Connect after an app switch creates a new
                    // encrypted route, but the old AVSampleBufferDisplayLayer
                    // and H.264 dependency chain can still be present. Keep
                    // input and video on the same session boundary: discard
                    // queued packets, require an IDR, and let the Mac refresh
                    // its ScreenCaptureKit source from the matching
                    // `startFallback` request below. Without this reset the
                    // control socket can be healthy while the viewer remains
                    // on the last pre-background frame.
                    self.peers.prepareForForegroundResume()
                    self.videoDisplay.prepareForForegroundResume()
                    self.frame = nil
                    self.resetVideoRateWindow()
                    self.connectionHealthDetail = "Reconnected — requesting a fresh Mac frame"
                }
                if self.canReadSystemPasteboard {
                    // A connection itself is not a clipboard change.  Do not
                    // read the current pasteboard merely to establish a
                    // baseline; that would show iPadOS's prompt on every
                    // reconnect.  Actual copies made while connected are
                    // handled by the change observer.
                    self.lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
                } else {
                    // Do not touch pasteboard contents during a background
                    // reconnect.  The foreground reconciliation pass will
                    // detect and transfer the latest local copy once the user
                    // returns, without a prompt appearing over another app.
                }
                self.suppressedClipboardSignature = nil
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
                self.lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
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
                self.resetVideoRateWindow()
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
                self.pendingFileURLs.removeAll(keepingCapacity: false)
                self.queuedFileCount = 0
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
            // The legacy/local fallback delivers decoded JPEG frames through
            // this callback rather than the H.264 callback below. Count the
            // received frame independently from display-layer back-pressure;
            // a healthy connection must not report 0 FPS merely because the
            // decoder is waiting for room in its short queue.
            self.recordVideoFrame()
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
            // Measure transport delivery rather than the return value of
            // enqueue(_:). The latter can be false during an intentional
            // keyframe recovery even while the encrypted stream is healthy.
            self.recordVideoFrame()
            let displayed = self.videoDisplay.enqueue(frame)
            if !displayed, frame.isKeyFrame {
                self.retryInitialKeyFrameAfterDisplayAppears(frame)
            }
        }
        configureFileTransfer()
        refreshReceivedFiles()
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
        sendFiles(at: [url])
    }

    func sendFiles(at urls: [URL]) {
        guard isConnected else {
            fileTransferError = "Connect the Mac before sending files."
            return
        }
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else {
            fileTransferError = "No local files were found to send."
            return
        }
        pendingFileURLs.append(contentsOf: files)
        queuedFileCount = pendingFileURLs.count
        fileTransferError = nil
        startNextQueuedFileIfNeeded()
    }

    func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard isConnected else {
            fileTransferError = "Connect the Mac before dropping files."
            return false
        }
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { [weak self] object, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let url = object {
                        self.sendFiles(at: [url])
                    } else if let error {
                        self.fileTransferError = error.localizedDescription
                    }
                }
            }
        }
        return accepted
    }

    func cancelFileTransfer() {
        pendingFileURLs.removeAll(keepingCapacity: false)
        queuedFileCount = 0
        guard fileTransfer.isBusy else { return }
        fileTransfer.cancelAll(reason: "Transfer canceled from the iPad.")
        fileTransferError = "Transfer canceled."
    }

    /// Refreshes the app-owned Documents subfolder exposed in the Files app.
    /// Partial files are intentionally hidden from the manager until the
    /// transfer engine has verified and atomically renamed them.
    func refreshReceivedFiles() {
        guard let directory = transferDirectoryURL else {
            receivedFiles = []
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            receivedFiles = urls.compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                ), values.isRegularFile == true else { return nil }
                return ReceivedFile(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
        } catch {
            fileTransferError = "Could not read received files: \(error.localizedDescription)"
        }
    }

    func deleteReceivedFile(_ file: ReceivedFile) {
        guard let directory = transferDirectoryURL else { return }
        let directoryPath = directory.standardizedFileURL.path
        let fileURL = file.url.standardizedFileURL
        guard fileURL.deletingLastPathComponent().path == directoryPath else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
            if lastReceivedFile?.standardizedFileURL == fileURL {
                lastReceivedFile = nil
            }
            refreshReceivedFiles()
            fileTransferError = nil
        } catch {
            fileTransferError = "Could not delete \(file.name): \(error.localizedDescription)"
        }
    }

    func submitPairingCode() {
        let normalized = PairingCode.normalize(pairingCode)
        guard normalized.count == PairingCode.characterCount else {
            pairingError = "Enter all 16 digits shown in the Mac app."
            return
        }

        // A pairing code is an authentication secret, not a network address.
        // Use the selected/remembered Mac (or the sole discovered Mac) as the
        // route, then submit the code before the handshake arrives. This makes
        // code-first pairing reliable without silently connecting when a Mac
        // is merely discovered.
        let targetName = selectedMacName ?? (discoveredMacs.count == 1 ? discoveredMacs[0] : nil)
        guard isConnected || targetName != nil else {
            pairingError = "Select a Mac card first; the code authenticates that Mac."
            return
        }

        pairingError = nil
        pairingRequired = true
        if !isConnected, !isConnecting, let targetName {
            userRequestedConnection = true
            isConnecting = true
            armConnectionTimeout()
            connect(to: targetName, detail: "Connecting with your 16-digit pairing code…")
        } else if let targetName {
            pairingMacName = targetName
        }
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
            guard let self else { return }
            self.lastReceivedFile = url
            self.refreshReceivedFiles()
            self.fileTransferError = nil
            self.placeReceivedFileOnClipboard(url)
        }
        fileTransfer.onError = { [weak self] message in
            self?.pendingFileURLs.removeAll(keepingCapacity: false)
            self?.queuedFileCount = 0
            self?.fileTransferError = message
        }
    }

    private func startNextQueuedFileIfNeeded() {
        guard isConnected, !fileTransfer.isBusy, let next = pendingFileURLs.first else {
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
        beginDiscoveryClock(incrementAttempt: false)
        peers.start()
        if let rememberedMac = selectedMacName {
            if !discoveredMacs.contains(rememberedMac) {
                discoveredMacs = [rememberedMac]
            }
            status = "Ready — enter the code or tap Connect"
            detail = "Remembered Mac: \(rememberedMac). The code field stays available for first-time pairing."
        } else {
            status = "Enter a code or choose a Mac"
            detail = "Discovery runs passively. Enter the Mac's 16-digit code below, or select a device card when it appears."
        }
    }

    func retry() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        isConnecting = false
        status = "Ready to connect"
        detail = "Refreshing the device list in the background. The 16-digit code remains available below."
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
                DiagnosticField("Received frame rate", streamFPS > 0 ? "\(streamFPS) FPS" : "Not measured"),
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
            let shouldRestoreStream = enteredBackground && restoreStreamAfterBackground
            let wasBackgrounded = applicationIsBackgrounded
            applicationIsBackgrounded = false
            enteredBackground = false
            if !shouldRestoreStream {
                restoreStreamAfterBackground = false
            }
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
                // Reset both halves of the video pipeline before resuming the
                // encrypted socket. This prevents stale H.264 P-frames from
                // being delivered into a new AVSampleBufferDisplayLayer while
                // the input channel appears healthy.
                peers.prepareForForegroundResume()
                videoDisplay.prepareForForegroundResume()
                beginForegroundResumePresentation()
            }
            // Returning to the foreground may restore a session the user
            // already started, but the initial active transition must never
            // dial a remembered Mac just because the Remote Control tab is
            // visible. Discovery publishes cards; Connect is explicit.
            if started, userRequestedConnection && (wasBackgrounded || shouldRestoreStream || !isConnected) {
                if userRequestedConnection, !isConnected { isConnecting = true }
                peers.resumeAfterBackground()
            }
            if isConnected {
                peers.send(ControlMessage(.status, detail: "viewer-foreground"))
                reconcileClipboardAfterForeground()
            }
            endBackgroundTask()
        case .background:
            appDidEnterBackground()
        case .inactive:
            appWillResignActive()
        @unknown default:
            break
        }
    }

    /// Called by UIApplication.willResignActiveNotification as an early
    /// lifecycle hook. SwiftUI's `.inactive` phase can be delivered only after
    /// iPadOS has started the suspension transition, which is too late for a
    /// reliable automatic PiP handoff on some iPadOS versions.
    func appWillResignActive() {
        // Flush a copy made immediately before the app switch before iPadOS
        // begins suspending the process.
        if isConnected { observeClipboardChange(force: false) }
        // Do not mark the peer as backgrounded yet: inactive is also emitted
        // for Control Center, permission sheets, and transient scene changes.
        // The actual did-enter-background callback owns that state transition
        // so a quick return does not unnecessarily tear down or redial a live
        // encrypted session.
        if isConnected || isStreaming || fileTransfer.isBusy || !pendingFileURLs.isEmpty {
            beginBackgroundGracePeriodIfNeeded()
        }
        // AVKit must see the automatic-start flag while the scene is still
        // active. Calling startPictureInPicture() after the app has already
        // entered the background is too late on current iPadOS releases.
        if isStreaming, keepRunningInBackground {
            videoDisplay.setAutomaticBackgroundStart(true)
            backgroundViewerDetail = isPictureInPicturePossible
                ? "Preparing Picture in Picture for the app switch…"
                : "Preparing the background viewer; preserving the session for fast resume."
        }
    }

    /// The inactive notification also fires for transient system UI such as
    /// Control Center or a permission alert. Wait for the actual background
    /// transition before asking AVKit to start PiP; doing that work too early
    /// races iPadOS 26/27's scene handoff and leaves the viewer unavailable.
    func appDidEnterBackground() {
        if !enteredBackground {
            enteredBackground = true
            restoreStreamAfterBackground = isStreaming
        }
        beginBackgroundTransition()
    }

    /// Reconcile clipboard changes made while the app was in another scene or
    /// briefly suspended. The monitor also polls while the process is kept
    /// alive by Picture in Picture; this active-transition path covers the
    /// case where iPadOS suspended the process before the copy notification.
    func clipboardDidChange() {
        observeClipboardChange(force: false)
    }

    private func startClipboardMonitoring() {
        guard automaticClipboardSyncEnabled, clipboardChangeObserver == nil else { return }

        clipboardChangeObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clipboardDidChange()
            }
        }

        // Do not poll the pasteboard.  Notifications are enough while the
        // app is active, and scene transitions reconcile a missed change.
        // Removing the timer keeps pasteboard work off the video cadence.
    }

    private func stopClipboardMonitoring() {
        clipboardMonitorTask?.cancel()
        clipboardMonitorTask = nil
        if let clipboardChangeObserver {
            NotificationCenter.default.removeObserver(clipboardChangeObserver)
            self.clipboardChangeObserver = nil
        }
    }

    /// If the iPad pasteboard did not change while it was away, pull the Mac's
    /// latest value. If it did change, the normal observer sends the iPad's
    /// value instead. This recovers a Mac copy whose packet arrived while the
    /// iPad process was suspended without blindly overwriting a local copy.
    private func reconcileClipboardAfterForeground() {
        guard isConnected, automaticClipboardSyncEnabled, !isStreaming else { return }
        let before = lastObservedClipboardChangeCount
        observeClipboardChange(force: false)
        // observeClipboardChange has already performed the one permitted read
        // for a changed pasteboard. Avoid a second read just to decide whether
        // the Mac should be queried.
        guard lastObservedClipboardChangeCount == before else { return }
        peers.send(ControlMessage(.requestClipboard))
    }

    private func beginBackgroundTransition() {
        prepareConnectionForBackgroundIfNeeded()
        let hasTransferWork = fileTransfer.isBusy || !pendingFileURLs.isEmpty
        let shouldProtectClipboard = isConnected && automaticClipboardSyncEnabled
        // A short iPadOS background task protects an active file transfer and
        // gives a copy made during the app-switch transition time to cross the
        // link. PiP remains the only supported way to keep an open-ended
        // background session alive.
        if hasTransferWork || shouldProtectClipboard { beginBackgroundGracePeriodIfNeeded() }
        guard isStreaming, keepRunningInBackground else {
            backgroundViewerDetail = isStreaming
                ? "Automatic background viewing is off. Return here to keep controlling the Mac."
                : hasTransferWork
                    ? "Finishing the current automatic transfer before iPadOS suspends the app."
                    : "Connect to a Mac first; the background viewer will be ready after the first frame."
            return
        }

        // The notification and scene-phase callbacks can both arrive for one
        // app switch. Keep one PiP request and one short background grace task;
        // repeating them makes AVKit race its own transition.
        guard !backgroundRequested else { return }
        backgroundRequested = true
        beginBackgroundGracePeriodIfNeeded()
        backgroundViewerDetail = isPictureInPicturePossible
            ? "Starting Picture in Picture…"
            : "Preparing the background viewer; preserving the session for fast resume."
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
        guard isConnected else {
            status = "Connect to a Mac first"
            detail = "Select a Mac card and tap Connect before starting In-App Display."
            return
        }
        let hasLiveVideoSession = isStreaming
            || frame != nil
            || videoDisplay.hasPictureInPictureContent
        if hasLiveVideoSession {
            // This button is also the manual recovery action after iPadOS
            // returns from another app while the encrypted input channel is
            // still alive. Treat it like a reconnect at the media layer: the
            // old display-layer dependency chain must not survive into the
            // new Mac capture/IDR requested by `startFallback`.
            peers.prepareForForegroundResume()
            videoDisplay.prepareForForegroundResume()
            frame = nil
            resetVideoRateWindow()
            connectionHealthDetail = "Refreshing the Mac display"
        }
        peers.send(ControlMessage(.startFallback))
        status = "Requesting app stream…"
        detail = hasLiveVideoSession
            ? "Requesting a fresh Mac frame for the resumed encrypted stream."
            : "Approve Screen Recording on the Mac if asked."
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

    func setStreamResolution(_ resolution: StreamResolutionPreference) {
        streamResolution = resolution
        UserDefaults.standard.set(resolution.rawValue, forKey: StreamPreferenceStore.resolutionKey)
        if isConnected {
            sendDisplayCapabilities()
        }
    }

    func setStreamFrameRate(_ frameRate: StreamFrameRatePreference) {
        let safeFrameRate = ultraModeEnabled
            ? frameRate
            : StreamFrameRatePreference(rawValue: min(frameRate.rawValue, StreamCadencePolicy.nearbyFrameRateCeiling)) ?? .fps120
        streamFrameRate = safeFrameRate
        StreamPreferenceStore.saveFrameRate(safeFrameRate)
        if isConnected {
            sendDisplayCapabilities()
        }
    }

    func setUltraModeEnabled(_ enabled: Bool) {
        ultraModeEnabled = enabled
        StreamPreferenceStore.saveUltraMode(enabled)
        if !enabled, streamFrameRate.rawValue > StreamCadencePolicy.nearbyFrameRateCeiling {
            streamFrameRate = .fps120
            StreamPreferenceStore.saveFrameRate(streamFrameRate)
        }
        if isConnected {
            sendDisplayCapabilities()
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
        resetVideoRateWindow()
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
        guard canReadSystemPasteboard else {
            clipboardTransferStatus = "Return to SidecarBridge to send the clipboard without a paste prompt."
            return
        }
        sendClipboardToMac(readClipboardPayload())
    }

    private func sendClipboardToMac(_ payload: ClipboardPayload) {
        guard isConnected else {
            clipboardTransferStatus = "Connect to the Mac before sending the clipboard."
            return
        }
        let files = payload.files
        if !files.isEmpty {
            sendFiles(at: files)
            clipboardTransferStatus = files.count == 1
                ? "Sending the copied file to the Mac…"
                : "Sending \(files.count) copied files to the Mac…"
            return
        }
        guard let text = payload.text, !text.isEmpty else {
            clipboardTransferStatus = "The iPad clipboard has no text or files to send."
            return
        }
        let prepared = ClipboardTransfer.prepare(text)
        peers.send(.clipboardText(prepared))
        clipboardTransferStatus = prepared == text
            ? "iPad clipboard sent to Mac."
            : "iPad clipboard sent (truncated to 48 KB)."
    }

    private func clipboardFileURLs() -> [URL] {
        (UIPasteboard.general.urls ?? []).filter { $0.isFileURL }
    }

    private func readClipboardPayload() -> ClipboardPayload {
        // Presence checks are metadata-only. Read text first so a copied web
        // link needs one content read; only inspect URL representations when
        // there is no text representation (the usual Files-app case). This
        // avoids two privacy-sensitive reads for a single clipboard change.
        if UIPasteboard.general.hasStrings {
            let text = UIPasteboard.general.string
            if let text, !text.isEmpty {
                return ClipboardPayload(files: [], text: text)
            }
        }
        if UIPasteboard.general.hasURLs {
            return ClipboardPayload(files: clipboardFileURLs(), text: nil)
        }
        return ClipboardPayload(files: [], text: nil)
    }

    private func placeReceivedFileOnClipboard(_ url: URL) {
        guard automaticClipboardSyncEnabled else { return }
        // Keep the app-owned received-file list instead of reading the
        // existing general pasteboard.  The latter can trigger iPadOS's paste
        // privacy alert for every incoming file; replacing the clipboard on
        // the first received file and appending subsequent files gives the
        // same transfer behavior without any extra prompt.
        let currentFiles = automaticReceivedFileURLs
        let currentSignature = ClipboardTransfer.fileSignature(currentFiles)
        let receivedSignature = ClipboardTransfer.fileSignature(automaticReceivedFileURLs)
        let isAppending = currentSignature == receivedSignature
            || lastObservedClipboardSignature == receivedSignature
        let baseFiles = currentSignature == receivedSignature
            ? currentFiles
            : automaticReceivedFileURLs
        let nextFiles = isAppending
            ? ClipboardTransfer.uniqueFileURLs(baseFiles + [url])
            : [url]
        automaticReceivedFileURLs = nextFiles
        let signature = ClipboardTransfer.fileSignature(nextFiles)
        suppressedClipboardSignature = signature
        UIPasteboard.general.urls = nextFiles
        lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
        lastObservedClipboardSignature = signature
        clipboardTransferStatus = nextFiles.count == 1
            ? "Received \(url.lastPathComponent) and copied it to the iPad clipboard."
            : "Received \(nextFiles.count) files and copied them to the iPad clipboard."
    }

    private func observeClipboardChange(force: Bool) {
        // Never let a paste privacy prompt interrupt the live screen.  Users
        // can still use the explicit Send Clipboard button while streaming.
        guard isConnected, automaticClipboardSyncEnabled, !isStreaming else { return }
        let changeCount = UIPasteboard.general.changeCount
        guard force || changeCount != lastObservedClipboardChangeCount else { return }
        // Keep the connection alive while backgrounded, but do not read the
        // general pasteboard over another app.  Reading there can make
        // iPadOS show its paste privacy prompt repeatedly; leaving the change
        // count untouched lets the foreground pass process it exactly once.
        guard canReadSystemPasteboard else { return }
        // A disabled sync setting must also be a hard privacy boundary: do
        // not inspect the clipboard just to learn that it changed.  The next
        // copy after the user re-enables sync will be transferred normally.
        lastObservedClipboardChangeCount = changeCount
        let payload = readClipboardPayload()
        let signature = payload.signature

        if signature == suppressedClipboardSignature {
            suppressedClipboardSignature = nil
            lastObservedClipboardSignature = signature
            return
        }
        if signature != ClipboardTransfer.fileSignature(automaticReceivedFileURLs) {
            automaticReceivedFileURLs.removeAll(keepingCapacity: false)
        }
        if suppressedClipboardSignature != nil {
            suppressedClipboardSignature = nil
        }
        guard let signature else {
            return
        }
        guard force || signature != lastObservedClipboardSignature else {
            return
        }
        lastObservedClipboardSignature = signature
        sendClipboardToMac(payload)
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
        guard duration >= 0.5 else {
            // Do not publish a fabricated 1-FPS value while the first
            // half-second measurement is still collecting samples. That value
            // was routinely mistaken for the Mac's actual send cadence when
            // the display layer had not presented its first burst yet.
            return
        }
        streamFPS = max(0, Int((Double(frameWindowCount) / duration).rounded()))
        frameWindowCount = 0
        frameWindowStart = now
    }

    private func resetVideoRateWindow() {
        frameWindowStart = ProcessInfo.processInfo.systemUptime
        frameWindowCount = 0
        streamFPS = 0
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
        // Frame metadata is stable for the lifetime of a stream. Avoid
        // rebuilding the aspect-ratio and dimensions strings on every H.264
        // sample; at 120 FPS this otherwise creates needless main-actor work.
        let metadataChanged = safeWidth != presentedStreamWidth
            || safeHeight != presentedStreamHeight
            || format != presentedStreamFormat
        guard metadataChanged || !isStreaming else { return }
        if metadataChanged {
            presentedStreamWidth = safeWidth
            presentedStreamHeight = safeHeight
            presentedStreamFormat = format
        }
        let ratio = CGFloat(safeWidth) / CGFloat(safeHeight)
        if abs(streamAspectRatio - ratio) > 0.0001 {
            streamAspectRatio = ratio
        }
        let dimensions = "\(safeWidth) × \(safeHeight) \(format)"
        if streamDimensions != dimensions {
            streamDimensions = dimensions
        }
        guard !isStreaming else { return }
        resetVideoRateWindow()
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
        peers.send(ControlMessage(.hello, detail: StreamPreferences(
            resolution: streamResolution,
            frameRate: streamFrameRate,
            ultraModeEnabled: ultraModeEnabled
        ).encodedDetail))
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

    private func beginBackgroundGracePeriodIfNeeded() {
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
                // Automatic PiP is handed off by AVKit during the scene
                // transition. Manual starts are only valid while the app is
                // foreground; do not race the suspended scene by calling the
                // API from the background.
                if self.isPictureInPicturePossible,
                   UIApplication.shared.applicationState == .active {
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
            sendClipboardToMac()
            return
        }
        if command.kind == .clipboardText {
            guard let text = command.clipboardTextPayload else {
                clipboardTransferStatus = "The received clipboard text was invalid or too large."
                return
            }
            suppressedClipboardSignature = "text:\(text)"
            automaticReceivedFileURLs.removeAll(keepingCapacity: false)
            UIPasteboard.general.string = text
            lastObservedClipboardChangeCount = UIPasteboard.general.changeCount
            lastObservedClipboardSignature = "text:\(text)"
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
        case StreamSessionSignal.videoRefresh:
            // A quality change can rebuild the Mac encoder while the secure
            // input socket stays healthy. Reset only the media decoder and
            // keep the viewer mounted; the next monotonic keyframe resumes
            // video without making the user reconnect.
            videoDisplay.prepareForForegroundResume()
            resetVideoRateWindow()
            connectionHealthDetail = "Refreshing Mac video profile"
            detail = "Applying the new video profile…"
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
