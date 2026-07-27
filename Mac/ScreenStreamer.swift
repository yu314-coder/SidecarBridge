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
    private var lastFrameTime: TimeInterval = 0
    private var preferredWidth = 2360
    private var transportProfile: TransportProfile = .direct
    private var activeFrameRate = 40
    private var foregroundFrameRate = 40
    private var viewerIsBackgrounded = false

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
            self.activeFrameRate = backgrounded ? min(self.foregroundFrameRate, 15) : self.foregroundFrameRate
        }
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw StreamError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw StreamError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let targetWidth = transportProfile == .nearbyP2P
            ? min(preferredWidth, 1728)
            : preferredWidth
        foregroundFrameRate = transportProfile == .nearbyP2P ? 30 : 40
        activeFrameRate = viewerIsBackgrounded ? min(foregroundFrameRate, 15) : foregroundFrameRate
        let targetBitrate = transportProfile == .nearbyP2P ? 5_000_000 : nil
        let scale = min(1.0, Double(targetWidth) / Double(display.width))
        configuration.width = max(960, Int(Double(display.width) * scale)) & ~1
        configuration.height = max(540, Int(Double(display.height) * scale)) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(activeFrameRate))
        configuration.queueDepth = 2
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
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
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
