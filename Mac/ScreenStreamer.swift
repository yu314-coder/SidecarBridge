import AppKit
import ScreenCaptureKit

final class ScreenStreamer: NSObject, SCStreamOutput {
    enum TransportProfile {
        case direct
        case nearbyP2P
    }

    enum StreamError: LocalizedError {
        case permissionRequired
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Grant Screen Recording permission, then quit and reopen SidecarBridge."
            case .noDisplay:
                return "No Mac display is available to capture."
            }
        }
    }

    var onFrame: ((VideoFrame) -> Void)?

    private let captureQueue = DispatchQueue(label: "io.sidecarbridge.capture", qos: .userInteractive)
    private let encoder = H264Encoder()
    private var stream: SCStream?
    /// The display selected by ScreenCaptureKit for this stream. Input events
    /// must target the same display; the main display can differ when an
    /// external monitor is attached.
    private(set) var captureDisplayID: CGDirectDisplayID?
    private var lastFrameTime: TimeInterval = 0
    private var preferredWidth = 2360
    private var transportProfile: TransportProfile = .direct
    private var activeFrameRate = 40
    private var foregroundFrameRate = 40
    private var viewerIsBackgrounded = false
    private var waitingForViewerResume = false

    func setPreferredWidth(_ width: Int) {
        preferredWidth = min(max(width, 1440), 2880)
    }

    func setTransportProfile(_ profile: TransportProfile) {
        transportProfile = profile
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

    func start() async throws {
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

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let targetWidth = transportProfile == .nearbyP2P
            ? min(preferredWidth, 1728)
            : preferredWidth
        foregroundFrameRate = transportProfile == .nearbyP2P ? 30 : 40
        updateActiveFrameRate()
        let targetBitrate = transportProfile == .nearbyP2P ? 5_000_000 : nil
        let scale = min(1.0, Double(targetWidth) / Double(display.width))
        configuration.width = max(960, Int(Double(display.width) * scale)) & ~1
        configuration.height = max(540, Int(Double(display.height) * scale)) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(activeFrameRate))
        // Keep only a small capture cushion. A deep ScreenCaptureKit queue
        // makes the viewer look smooth while adding avoidable end-to-end
        // latency when the link is busy.
        configuration.queueDepth = transportProfile == .nearbyP2P ? 2 : 3
        // Capture the real Mac cursor. The iPad viewer deliberately does not
        // draw a second software cursor, so the pointer users see is the one
        // that WindowServer actually moved after a remote input event.
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        configuration.colorSpaceName = CGColorSpace.sRGB

        encoder.onFrame = { [weak self] frame in self?.onFrame?(frame) }
        try encoder.start(
            width: configuration.width,
            height: configuration.height,
            frameRate: activeFrameRate,
            targetBitrate: targetBitrate
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        encoder.stop()
        captureDisplayID = nil
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    private func updateActiveFrameRate() {
        if waitingForViewerResume {
            activeFrameRate = 2
        } else if viewerIsBackgrounded {
            activeFrameRate = min(foregroundFrameRate, 15)
        } else {
            activeFrameRate = foregroundFrameRate
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
