import AppKit
@preconcurrency import ScreenCaptureKit

final class ScreenStreamer: NSObject, SCStreamOutput, @unchecked Sendable {
    /// ScreenCaptureKit's stream object is callback-driven and not annotated
    /// Sendable in the SDK. This small reference lets the async configuration
    /// task carry the already-owned stream without pretending its internals
    /// are independently thread-safe; all state changes still return through
    /// `captureQueue`.
    private final class StreamReference: @unchecked Sendable {
        let stream: SCStream

        init(_ stream: SCStream) {
            self.stream = stream
        }
    }

    /// ScreenCaptureKit does not support overlapping updateConfiguration
    /// calls. Cancelling a Swift Task is not a completion barrier for an
    /// Objective-C operation already running inside ScreenCaptureKit, so every
    /// update is serialized here and stale work is cancelled only after its
    /// predecessor has finished.
    private final class StreamConfigurationScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Task<Void, Never>?
        private var acceptsUpdates = true

        /// Re-enable scheduling when a new SCStream is about to start. Any
        /// completed task left in `pending` is harmless and becomes the
        /// predecessor of the first update on the new stream.
        func activate() {
            lock.lock()
            acceptsUpdates = true
            lock.unlock()
        }

        /// Synchronously close the gate before a stream is stopped. This is
        /// important because a caller on another queue may already have built
        /// an update task but not yet submitted it to this scheduler.
        func invalidate() -> Task<Void, Never>? {
            lock.lock()
            acceptsUpdates = false
            let current = pending
            current?.cancel()
            lock.unlock()
            return current
        }

        func schedule(
            stream: StreamReference,
            configuration: SCStreamConfiguration,
            onSuccess: @escaping @Sendable () -> Void
        ) {
            lock.lock()
            guard acceptsUpdates else {
                lock.unlock()
                return
            }
            let previous = pending
            previous?.cancel()
            let next = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                do {
                    try await stream.stream.updateConfiguration(configuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onSuccess()
            }
            pending = next
            lock.unlock()
        }

        private func beginApply(
            stream: StreamReference,
            configuration: SCStreamConfiguration
        ) throws -> Task<Bool, Never> {
            lock.lock()
            guard acceptsUpdates else {
                lock.unlock()
                throw StreamError.configurationUpdateFailed
            }
            let previous = pending
            previous?.cancel()
            let operation = Task<Bool, Never> {
                await previous?.value
                guard !Task.isCancelled else { return false }
                do {
                    try await stream.stream.updateConfiguration(configuration)
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }
            // Keep a void barrier for future scheduled updates while the
            // caller awaits this specific operation and retains its throwing
            // API.
            pending = Task { _ = await operation.value }
            lock.unlock()
            return operation
        }

        func apply(
            stream: StreamReference,
            configuration: SCStreamConfiguration
        ) async throws {
            let operation = try beginApply(
                stream: stream,
                configuration: configuration
            )
            guard await operation.value else {
                throw StreamError.configurationUpdateFailed
            }
        }
    }

    enum TransportProfile {
        case direct
        case nearbyP2P
    }

    enum StreamError: LocalizedError {
        case permissionRequired
        case noDisplay
        case configurationUpdateFailed

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Grant Screen Recording permission, then quit and reopen SidecarBridge."
            case .noDisplay:
                return "No Mac display is available to capture."
            case .configurationUpdateFailed:
                return "The display capture configuration could not be updated safely."
            }
        }
    }

    var onFrame: ((VideoFrame) -> Void)?
    /// Called after a foreground resume has rebuilt the ScreenCaptureKit
    /// source. The Mac model uses this to retarget input when a display was
    /// attached or removed while the iPad viewer was away.
    var onCaptureRefreshCompleted: (() -> Void)?
    var onCaptureRefreshFailed: ((Error) -> Void)?
    var onMemoryPressureChanged: ((StreamMemoryPressureLevel) -> Void)?

    private let captureQueue = DispatchQueue(label: "io.sidecarbridge.capture", qos: .userInteractive)
    private let encoder = H264Encoder()
    private var stream: SCStream?
    /// The display selected by ScreenCaptureKit for this stream. Input events
    /// must target the same display; the main display can differ when an
    /// external monitor is attached.
    private(set) var captureDisplayID: CGDirectDisplayID?
    private var lastFrameTime: TimeInterval = 0
    private var preferredWidth = 2360
    private var streamPreferences = StreamPreferences.defaults
    private var transportProfile: TransportProfile = .direct
    private var activeFrameRate = 60
    // Direct local TCP can target the connected display's high-refresh mode.
    // Nearby Multipeer can now target the selected 90/120-FPS cadence in the
    // foreground; bounded queues and backpressure still protect slow links.
    private var foregroundFrameRate = 60
    private var displayRefreshRate = 60
    private var viewerIsBackgrounded = false
    private var waitingForViewerResume = false
    private var memoryPressureLevel: StreamMemoryPressureLevel = .normal
    private var transportBackpressure: StreamBackpressureLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pendingMemoryPressureLevel: StreamMemoryPressureLevel?
    private var memoryPressureTransitionWorkItem: DispatchWorkItem?
    private var lastMemoryPressureApplyUptime: TimeInterval = 0
    private let memoryPressureMinimumDwell: TimeInterval = 2.0
    private let configurationScheduler = StreamConfigurationScheduler()
    private var foregroundRefreshTask: Task<Void, Never>?
    private var foregroundRefreshToken = UUID()
    private var lastForegroundRefreshUptime: TimeInterval = 0
    private let minimumForegroundRefreshInterval: TimeInterval = 0.75
    private var captureDisplayWidth = 0
    private var captureDisplayHeight = 0
    private var captureWidth = 0
    private var captureHeight = 0

    override init() {
        super.init()
        installMemoryPressureMonitor()
    }

    deinit {
        memoryPressureSource?.cancel()
        memoryPressureTransitionWorkItem?.cancel()
        let scheduler = configurationScheduler
        let inFlight = scheduler.invalidate()
        Task { await inFlight?.value }
    }

    func setPreferredWidth(_ width: Int) {
        preferredWidth = min(max(width, 1440), 2880)
    }

    func setStreamPreferences(_ preferences: StreamPreferences) {
        streamPreferences = preferences
        updateActiveFrameRate()
    }

    /// Applies a changed quality/FPS preference without dropping the
    /// authenticated session. ScreenCaptureKit supports updating a running
    /// configuration; only a resolution change needs a capture-source
    /// rebuild so VideoToolbox can use a matching encoder size.
    ///
    /// The caller sends a decoder-boundary signal when
    /// `requiresMediaBoundaryForCurrentPreferences` is true. Both paths keep
    /// the encoder sequence monotonic, so the input channel never has to
    /// reconnect just because the viewer profile changed.
    func applyStreamPreferences() async throws {
        guard stream != nil else { return }

        if requiresMediaBoundaryForCurrentPreferences {
            try await rebuildCaptureAfterForeground()
            return
        }

        guard let stream else { return }
        let configuration = makeConfiguration(
            width: captureWidth,
            height: captureHeight,
            frameRate: activeFrameRate
        )
        let reference = StreamReference(stream)
        try await configurationScheduler.apply(
            stream: reference,
            configuration: configuration
        )
        captureQueue.sync { encoder.requestKeyFrame() }
    }

    var requiresMediaBoundaryForCurrentPreferences: Bool {
        guard captureDisplayWidth > 0, captureDisplayHeight > 0,
              captureWidth > 0, captureHeight > 0 else { return true }
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        return dimensions.width != captureWidth || dimensions.height != captureHeight
    }

    /// Memory pressure can temporarily change the capture dimensions. The
    /// encoder dimensions are fixed for a compression session, so a quality
    /// downgrade or restoration needs the same guarded media boundary as a
    /// user-selected quality change.
    var requiresMediaBoundaryForCurrentMemoryProfile: Bool {
        guard captureDisplayWidth > 0, captureDisplayHeight > 0,
              captureWidth > 0, captureHeight > 0 else { return false }
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        return dimensions.width != captureWidth || dimensions.height != captureHeight
    }

    var isRefreshingCapture: Bool {
        foregroundRefreshTask != nil
    }

    func setTransportProfile(_ profile: TransportProfile) {
        transportProfile = profile
        updateActiveFrameRate()
    }

    /// Lets the sender throttle capture when its bounded network window is
    /// full. This keeps the Mac near the live edge instead of encoding frames
    /// that will immediately be discarded by the transport.
    func setTransportBackpressure(_ level: StreamBackpressureLevel) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.transportBackpressure != level else { return }
            self.transportBackpressure = level
            self.updateActiveFrameRate()
        }
    }

    func setViewerBackgrounded(_ backgrounded: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.viewerIsBackgrounded = backgrounded
            self.updateActiveFrameRate()
        }
    }

    func setWaitingForViewerResume(_ waiting: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.waitingForViewerResume = waiting
            self.updateActiveFrameRate()
        }
    }

    func requestKeyFrame() {
        captureQueue.async { [weak self] in
            self?.encoder.requestKeyFrame()
        }
    }

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .all,
            queue: captureQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.memoryPressureSource?.data ?? []
            let level: StreamMemoryPressureLevel
            if events.contains(.critical) {
                level = .critical
            } else if events.contains(.warning) {
                level = .warning
            } else if events.contains(.normal) {
                level = .normal
            } else {
                return
            }
            self.scheduleMemoryPressureProfile(level)
        }
        memoryPressureSource = source
        source.resume()
    }

    /// DispatchSourceMemoryPressure can report warning/normal transitions in
    /// quick succession while the system is reclaiming IOSurfaces. Applying
    /// every event immediately used to rebuild the capture source repeatedly,
    /// which looked like a frozen/1-FPS stream even though input packets kept
    /// moving. Apply pressure changes with a short entry debounce and a longer
    /// normal-state dwell so one transient sample cannot thrash ScreenCaptureKit.
    private func scheduleMemoryPressureProfile(_ level: StreamMemoryPressureLevel) {
        guard level != memoryPressureLevel || pendingMemoryPressureLevel != nil else { return }
        pendingMemoryPressureLevel = level
        memoryPressureTransitionWorkItem?.cancel()

        let now = ProcessInfo.processInfo.systemUptime
        let entryDelay: TimeInterval = switch level {
        case .critical: 0.1
        case .warning: 0.35
        case .normal: 1.5
        }
        let earliestNextApply = lastMemoryPressureApplyUptime + memoryPressureMinimumDwell
        let delay = max(entryDelay, max(0, earliestNextApply - now))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingMemoryPressureLevel == level else { return }
            self.pendingMemoryPressureLevel = nil
            self.memoryPressureTransitionWorkItem = nil
            self.memoryPressureLevel = level
            self.lastMemoryPressureApplyUptime = ProcessInfo.processInfo.systemUptime
            self.encoder.setMemoryPressure(level)
            self.updateActiveFrameRate()
            self.encoder.requestKeyFrame()
            self.onMemoryPressureChanged?(level)
        }
        memoryPressureTransitionWorkItem = workItem
        captureQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Rebuild the ScreenCaptureKit source after the viewer returns from an
    /// iPadOS background/PiP transition. ScreenCaptureKit can keep delivering
    /// a valid-looking sample buffer from the pre-background presentation
    /// surface even though the input socket is still healthy. A fresh
    /// SCStream forces WindowServer to bind a current display surface; the
    /// encoder keeps its packet sequence so a duplicate foreground callback
    /// cannot make the receiver reject every new frame as stale.
    func refreshCaptureAfterForeground(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard stream != nil else {
            requestKeyFrame()
            return
        }
        guard force || now - lastForegroundRefreshUptime >= minimumForegroundRefreshInterval else {
            requestKeyFrame()
            return
        }
        lastForegroundRefreshUptime = now
        foregroundRefreshTask?.cancel()
        let token = UUID()
        foregroundRefreshToken = token
        foregroundRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundRefreshToken == token {
                    self.foregroundRefreshTask = nil
                }
            }
            do {
                try await self.rebuildCaptureAfterForeground()
                guard !Task.isCancelled else { return }
                self.onCaptureRefreshCompleted?()
            } catch {
                guard !Task.isCancelled else { return }
                self.onCaptureRefreshFailed?(error)
                // A keyframe is still useful if the old capture source could
                // not be rebuilt (for example while a monitor is reattaching).
                self.requestKeyFrame()
            }
        }
    }

    func start(resetSequence: Bool = true) async throws {
        guard stream == nil else { return }
        try await startCapture(resetSequence: resetSequence)
        if !resetSequence {
            captureQueue.sync { encoder.requestKeyFrame() }
        }
    }

    private func startCapture(resetSequence: Bool) async throws {
        configurationScheduler.activate()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw StreamError.permissionRequired
        }

        // Include displays even when they do not currently have an on-screen
        // window.  An external monitor, a clamshell display, or a display
        // that has just been attached can otherwise be omitted from
        // ScreenCaptureKit's filtered list even though it is capturable.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let onlineDisplays = content.displays.filter { display in
            let isOnline = CGDisplayIsOnline(display.displayID) != 0
            let isActive = CGDisplayIsActive(display.displayID) != 0
            return isOnline && isActive
        }
        let mainDisplayID = CGMainDisplayID()
        let mainDisplay = onlineDisplays.first { display in
            display.displayID == mainDisplayID
        }
        let largestDisplay = onlineDisplays.max { left, right in
            left.width * left.height < right.width * right.height
        }
        guard let display = mainDisplay ?? largestDisplay ?? content.displays.first else {
            throw StreamError.noDisplay
        }
        captureDisplayID = display.displayID
        captureDisplayWidth = display.width
        captureDisplayHeight = display.height
        displayRefreshRate = Self.refreshRate(for: display.displayID)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let dimensions = captureDimensions(
            displayWidth: display.width,
            displayHeight: display.height
        )
        foregroundFrameRate = transportProfile == .nearbyP2P
            ? min(
                streamPreferences.frameRate.rawValue,
                streamPreferences.ultraModeEnabled
                    ? StreamCadencePolicy.ultraFrameRateCeiling
                    : StreamCadencePolicy.nearbyFrameRateCeiling
            )
            : min(streamPreferences.frameRate.rawValue, displayRefreshRate)
        updateActiveFrameRate()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        captureWidth = configuration.width
        captureHeight = configuration.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(activeFrameRate))
        // Keep only a small capture cushion. A deep ScreenCaptureKit queue
        // makes the viewer look smooth while adding avoidable end-to-end
        // latency when the link is busy.
        configuration.queueDepth = StreamCadencePolicy.captureQueueDepth(for: activeFrameRate)
        // Capture the real Mac cursor. The iPad viewer deliberately does not
        // draw a second software cursor, so the pointer users see is the one
        // that WindowServer actually moved after a remote input event.
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB

        let targetBitrate = targetBitrate(
            width: configuration.width,
            height: configuration.height,
            frameRate: activeFrameRate
        )
        encoder.onFrame = { [weak self] frame in self?.onFrame?(frame) }
        lastFrameTime = 0
        try encoder.start(
            width: configuration.width,
            height: configuration.height,
            frameRate: activeFrameRate,
            targetBitrate: targetBitrate,
            resetSequence: resetSequence
        )
        encoder.setMemoryPressure(memoryPressureLevel)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            encoder.stop()
            try? await stream.stopCapture()
            throw error
        }
    }

    private func captureDimensions(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
        let requestedWidth = streamPreferences.resolution.maximumWidth.map {
            min(preferredWidth, $0)
        } ?? min(preferredWidth, 2360)
        let transportWidth = transportProfile == .nearbyP2P
            ? min(requestedWidth, streamPreferences.ultraModeEnabled ? 2560 : 1920)
            : min(requestedWidth, 2560)
        let targetWidth = memoryPressureLevel.captureWidthCeiling.map {
            min(transportWidth, $0)
        } ?? transportWidth
        let scale = min(1.0, Double(targetWidth) / Double(max(displayWidth, 1)))
        let width = max(960, Int(Double(displayWidth) * scale)) & ~1
        let height = max(540, Int(Double(displayHeight) * scale)) & ~1
        return (width, height)
    }

    private func makeConfiguration(width: Int, height: Int, frameRate: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = StreamCadencePolicy.captureQueueDepth(for: frameRate)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    func stop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        encoder.stop()
        captureDisplayID = nil
        guard let stream else { return }
        self.stream = nil
        let scheduler = configurationScheduler
        let inFlight = scheduler.invalidate()
        Task {
            await inFlight?.value
            try? await stream.stopCapture()
        }
    }

    private func rebuildCaptureAfterForeground() async throws {
        guard let oldStream = stream else {
            throw StreamError.noDisplay
        }

        // Stop the old source before touching VideoToolbox. Waiting for the
        // capture queue to drain prevents one final pre-background sample from
        // being encoded into the newly presented stream.
        self.stream = nil
        let inFlight = configurationScheduler.invalidate()
        await inFlight?.value
        try? await oldStream.stopCapture()
        captureQueue.sync { }
        encoder.stop()
        captureDisplayID = nil
        captureWidth = 0
        captureHeight = 0
        guard !Task.isCancelled else { return }

        // Build the same capture configuration as a normal start, but keep
        // the packet sequence continuous across this presentation-only
        // restart. The iPad decoder is already gated on a fresh keyframe.
        try await startCapture(resetSequence: false)
        guard !Task.isCancelled else {
            stop()
            return
        }
        // Make the first sample from the new source an IDR. The synchronous
        // hop establishes the request before any queued capture callback can
        // reach VideoToolbox.
        captureQueue.sync { encoder.requestKeyFrame() }
    }

    private func updateActiveFrameRate() {
        let previousActiveFrameRate = activeFrameRate
        foregroundFrameRate = transportProfile == .nearbyP2P
            ? min(
                streamPreferences.frameRate.rawValue,
                streamPreferences.ultraModeEnabled
                    ? StreamCadencePolicy.ultraFrameRateCeiling
                    : StreamCadencePolicy.nearbyFrameRateCeiling
            )
            : min(streamPreferences.frameRate.rawValue, displayRefreshRate)
        activeFrameRate = StreamCadencePolicy.effectiveFrameRate(
            requested: streamPreferences.frameRate.rawValue,
            displayRefreshRate: displayRefreshRate,
            isNearby: transportProfile == .nearbyP2P,
            viewerIsBackgrounded: viewerIsBackgrounded,
            waitingForViewerResume: waitingForViewerResume,
            memoryPressure: memoryPressureLevel,
            backpressure: transportBackpressure,
            ultraModeEnabled: streamPreferences.ultraModeEnabled
        )
        // Background/resume and memory-pressure state can change without
        // rebuilding SCStream. Keep VideoToolbox's timestamps, bitrate, and
        // packet cadence in lockstep with the capture gate so the receiver
        // never interprets a capped stream as a bursty higher-rate stream.
        encoder.setFrameRate(activeFrameRate)
        guard captureWidth > 0, captureHeight > 0 else { return }
        encoder.setTargetBitrate(
            targetBitrate(width: captureWidth, height: captureHeight, frameRate: activeFrameRate)
        )
        // A pressure/quality transition that changes dimensions is rebuilt as
        // one media boundary. Do not concurrently call
        // SCStream.updateConfiguration with the old dimensions; that race can
        // leave WindowServer feeding the old surface while the new encoder is
        // waiting for its first IDR.
        let dimensions = captureDimensions(
            displayWidth: captureDisplayWidth,
            displayHeight: captureDisplayHeight
        )
        guard dimensions.width == captureWidth, dimensions.height == captureHeight else {
            return
        }
        // Backpressure and memory notifications can arrive repeatedly while
        // the socket is draining. Re-applying an identical SCStream
        // configuration invalidates its capture queue and requests another
        // IDR, which is exactly the 2-to-60-FPS oscillation seen in ultra
        // mode. Only cross a media boundary when the effective cadence really
        // changed.
        guard activeFrameRate != previousActiveFrameRate else { return }
        updateCaptureConfigurationForActiveCadence()
    }

    /// Apply cadence changes to ScreenCaptureKit as well as the encoder. The
    /// software gate in `stream(_:didOutputSampleBuffer:)` protects latency,
    /// but leaving the capture source at 120 FPS would still spend memory and
    /// scheduling time producing frames that pressure mode immediately drops.
    private func updateCaptureConfigurationForActiveCadence() {
        guard let activeStream = stream,
              captureWidth > 0,
              captureHeight > 0 else { return }
        let configuration = makeConfiguration(
            width: captureWidth,
            height: captureHeight,
            frameRate: activeFrameRate
        )
        let reference = StreamReference(activeStream)
        configurationScheduler.schedule(
            stream: reference,
            configuration: configuration
        ) { [weak self, reference] in
            guard let self else { return }
            self.captureQueue.async { [weak self, reference] in
                guard let self, self.stream === reference.stream else { return }
                self.lastFrameTime = 0
                self.encoder.requestKeyFrame()
            }
        }
    }

    private func targetBitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let baseBitrate: Int
        if transportProfile != .direct && !streamPreferences.ultraModeEnabled {
            baseBitrate = 8_000_000
        } else {
            // Text-heavy 2K capture needs more bits than the old fixed 20 Mbps
            // setting. Scale from pixels and cadence, then keep a hard ceiling
            // so a 120-FPS request cannot turn a temporary Wi-Fi dip into an
            // unbounded TCP latency queue. This remains a target; VideoToolbox
            // may choose a lower rate on older hardware.
            let pixels = max(1, width * height)
            // High cadence multiplies frame count, but it should not multiply
            // the per-pixel budget without a ceiling. The old 40-Mbps cap was
            // reached by a 2K/120 stream, filling the short TCP window and
            // forcing a keyframe recovery loop. Keep text legible while
            // leaving headroom for the input channel and the iPad decoder.
            let pixelBudget = Double(pixels) * 4.5
            let cadenceScale = min(max(Double(frameRate) / 60.0, 1.0), 1.75)
            let calculated = Int(pixelBudget * cadenceScale)
            baseBitrate = min(max(calculated, 12_000_000), 32_000_000)
        }

        let pressureBitrate = Int(Double(baseBitrate) * memoryPressureLevel.bitrateMultiplier)
        // Under pressure, the bitrate floor must actually fall. The previous
        // unconditional 6 Mbps floor silently defeated the warning/critical
        // multipliers and kept large H.264 buffers resident while RAM was
        // already yellow.
        let floor = memoryPressureLevel == .normal ? 6_000_000 : 2_000_000
        return max(floor, pressureBitrate)
    }

    private static func refreshRate(for displayID: CGDirectDisplayID) -> Int {
        let currentRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        let availableRates = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? [])
            .map(\.refreshRate)
            .filter { $0.isFinite && $0 >= 1 }
        let rate = max(currentRate, availableRates.max() ?? 0)
        guard rate.isFinite, rate >= 1 else { return 60 }
        return min(max(Int(rate.rounded()), 1), 240)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A stopped SCStream can have one or two callbacks already queued on
        // its sample handler queue. Ignore those callbacks after a foreground
        // rebuild so an old surface can never overwrite the new capture.
        guard self.stream === stream else { return }
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= 1.0 / Double(activeFrameRate) else { return }
        lastFrameTime = now
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder.encode(pixelBuffer, presentationTime: presentationTime.isValid ? presentationTime : CMTime(seconds: now, preferredTimescale: 600))
    }
}
