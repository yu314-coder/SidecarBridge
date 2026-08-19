import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

@MainActor
final class VideoDisplayController: NSObject {
    var onPictureInPictureStateChanged: ((Bool, Bool, Bool) -> Void)?
    var onPictureInPictureError: ((String) -> Void)?

    private weak var view: VideoDisplayView?
    private weak var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var needsKeyFrame = true
    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    private var automaticBackgroundStartEnabled = true
    private var isStartingPictureInPicture = false
    private var pendingPictureInPictureStart = false
    private var hasReceivedSampleBuffer = false
    private var pictureInPictureStartWatchdog: Task<Void, Never>?
    private var pendingSamples: [CMSampleBuffer] = []
    private var displayDrainTask: Task<Void, Never>?
    private let maximumPendingSamples = 12

    var isPictureInPictureActive: Bool {
        pictureInPictureController?.isPictureInPictureActive == true
    }

    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var hasPictureInPictureContent: Bool {
        hasReceivedSampleBuffer
    }

    var isPictureInPicturePossible: Bool {
        pictureInPictureController?.isPictureInPicturePossible == true
    }

    func attach(_ view: VideoDisplayView) {
        let hadPendingSamples = !pendingSamples.isEmpty
        self.view = view
        configurePictureInPicture(for: view.displayLayer)
        if hadPendingSamples {
            hasReceivedSampleBuffer = true
        }
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline =
            automaticBackgroundStartEnabled && hasReceivedSampleBuffer
        drainDisplayQueue()
        attemptPendingPictureInPictureStart()
    }

    @discardableResult
    func enqueue(_ frame: VideoFrame) -> Bool {
        if frame.isKeyFrame, frame.parameterSets.count >= 2, frame.parameterSets != parameterSets {
            parameterSets = frame.parameterSets
            formatDescription = makeFormatDescription(parameterSets: frame.parameterSets)
            needsKeyFrame = formatDescription == nil
            hasReceivedSampleBuffer = false
            resetDisplayQueue()
        }
        guard let formatDescription, !needsKeyFrame || frame.isKeyFrame else { return false }
        guard let sampleBuffer = makeSampleBuffer(
            data: frame.sampleData,
            format: formatDescription,
            sequence: frame.sequence,
            isKeyFrame: frame.isKeyFrame
        ) else { return false }

        if view?.displayLayer.status == .failed {
            resetDisplayQueue()
            needsKeyFrame = true
            guard frame.isKeyFrame else { return false }
        }

        // H.264 P-frames depend on the preceding frames. Dropping an arbitrary
        // frame whenever AVSampleBufferDisplayLayer is briefly busy breaks the
        // dependency chain and leaves only the periodic keyframes visible
        // (which looked like a hard 4 FPS cap). Keep a short ordered queue and
        // drain it as soon as the display layer is ready.
        if pendingSamples.count >= maximumPendingSamples {
            resetDisplayQueue()
            needsKeyFrame = true
            guard frame.isKeyFrame else { return false }
        }
        needsKeyFrame = false
        pendingSamples.append(sampleBuffer)
        hasReceivedSampleBuffer = true
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = automaticBackgroundStartEnabled
        drainDisplayQueue()
        attemptPendingPictureInPictureStart()
        return true
    }

    /// Feeds the JPEG fallback into the same sample-buffer layer used by the
    /// H.264 path. The foreground viewer can remain a sharp UIImage while the
    /// layer supplies a real PiP content source when the Mac is on the older
    /// or lower-bandwidth transport.
    @discardableResult
    func enqueueJPEG(_ image: UIImage) -> Bool {
        guard let sampleBuffer = makeImageSampleBuffer(image) else { return false }
        if pendingSamples.count >= maximumPendingSamples {
            // JPEG frames are independent, so discard stale fallback frames
            // instead of allowing a suspended PiP layer to grow the queue.
            pendingSamples.removeAll(keepingCapacity: true)
            view?.flush()
        }
        hasReceivedSampleBuffer = true
        pendingSamples.append(sampleBuffer)
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = automaticBackgroundStartEnabled
        drainDisplayQueue()
        attemptPendingPictureInPictureStart()
        return true
    }

    func flush() {
        needsKeyFrame = true
        hasReceivedSampleBuffer = false
        resetDisplayQueue()
    }

    private func drainDisplayQueue() {
        guard let view else { return }
        while !pendingSamples.isEmpty, view.displayLayer.isReadyForMoreMediaData {
            view.enqueue(pendingSamples.removeFirst())
        }
        guard !pendingSamples.isEmpty, displayDrainTask == nil else { return }
        displayDrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2))
            guard let self else { return }
            self.displayDrainTask = nil
            self.drainDisplayQueue()
        }
    }

    private func resetDisplayQueue() {
        displayDrainTask?.cancel()
        displayDrainTask = nil
        pendingSamples.removeAll(keepingCapacity: true)
        hasReceivedSampleBuffer = false
        view?.flush()
    }

    @discardableResult
    func startPictureInPicture() -> Bool {
        guard let pictureInPictureController else {
            onPictureInPictureError?("Picture in Picture is not available on this iPad.")
            return false
        }
        if pictureInPictureController.isPictureInPictureActive { return true }
        if isStartingPictureInPicture { return true }
        // The controller can report that PiP is unavailable until its content
        // source has received a real sample. Keep an explicit request alive so
        // a fast app switch does not suspend the viewer before the first key
        // frame arrives.
        pendingPictureInPictureStart = true
        guard hasReceivedSampleBuffer else {
            publishPictureInPictureState()
            return true
        }
        // Refresh the sample-buffer playback delegate before reading
        // isPictureInPicturePossible. The first frame can arrive in the same
        // render pass that attaches the display layer, so the old state may
        // still say unavailable for a moment.
        pictureInPictureController.invalidatePlaybackState()
        guard pictureInPictureController.isPictureInPicturePossible else {
            publishPictureInPictureState()
            return true
        }
        pendingPictureInPictureStart = false
        pictureInPictureController.invalidatePlaybackState()
        isStartingPictureInPicture = true
        pictureInPictureController.startPictureInPicture()
        armPictureInPictureStartWatchdog(for: pictureInPictureController)
        return true
    }

    func togglePictureInPicture() {
        guard let pictureInPictureController else {
            onPictureInPictureError?("Picture in Picture is not available on this iPad.")
            return
        }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }

    func stopPictureInPicture() {
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = nil
        isStartingPictureInPicture = false
        pendingPictureInPictureStart = false
        pictureInPictureController?.stopPictureInPicture()
    }

    func setAutomaticBackgroundStart(_ enabled: Bool) {
        automaticBackgroundStartEnabled = enabled
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = enabled && hasReceivedSampleBuffer
    }

    private func configurePictureInPicture(for displayLayer: AVSampleBufferDisplayLayer) {
        guard pictureInPictureDisplayLayer !== displayLayer else {
            publishPictureInPictureState()
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onPictureInPictureStateChanged?(false, false, false)
            return
        }

        let contentIsReady = hasReceivedSampleBuffer || !pendingSamples.isEmpty
        pictureInPicturePossibleObservation = nil
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = nil
        isStartingPictureInPicture = false
        pendingPictureInPictureStart = false
        hasReceivedSampleBuffer = false
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        // Allow automatic PiP as soon as a real sample is already queued. If
        // the first frame arrived before SwiftUI mounted this view, leaving
        // this disabled would make the app suspend on the very first swipe.
        controller.canStartPictureInPictureAutomaticallyFromInline =
            automaticBackgroundStartEnabled && contentIsReady
        pictureInPictureDisplayLayer = displayLayer
        pictureInPictureController = controller
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publishPictureInPictureState()
                self.attemptPendingPictureInPictureStart()
            }
        }
    }

    private func publishPictureInPictureState() {
        onPictureInPictureStateChanged?(
            pictureInPictureController?.isPictureInPicturePossible == true,
            pictureInPictureController?.isPictureInPictureActive == true,
            pictureInPictureController?.isPictureInPictureSuspended == true
        )
    }

    private func attemptPendingPictureInPictureStart() {
        guard pendingPictureInPictureStart,
              hasReceivedSampleBuffer,
              let controller = pictureInPictureController,
              !controller.isPictureInPictureActive,
              !isStartingPictureInPicture,
              controller.isPictureInPicturePossible else { return }
        pendingPictureInPictureStart = false
        _ = startPictureInPicture()
    }

    private func armPictureInPictureStartWatchdog(for controller: AVPictureInPictureController) {
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = Task { [weak self, weak controller] in
            // Starting while the scene transitions can legitimately take
            // several seconds. A three-second watchdog cancelled successful
            // starts on slower devices before iPadOS finished the handoff.
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  let controller,
                  self.isStartingPictureInPicture,
                  !controller.isPictureInPictureActive else { return }
            self.isStartingPictureInPicture = false
            controller.stopPictureInPicture()
            self.publishPictureInPictureState()
            self.onPictureInPictureError?("Picture in Picture start timed out; SidecarBridge will retry automatically.")
        }
    }

    private func makeImageSampleBuffer(_ image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0 else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func makeFormatDescription(parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard parameterSets.count >= 2 else { return nil }
        return parameterSets[0].withUnsafeBytes { spsBytes in
            parameterSets[1].withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
                let pointers = [sps, pps]
                let sizes = [parameterSets[0].count, parameterSets[1].count]
                var format: CMVideoFormatDescription?
                let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
                return status == noErr ? format : nil
            }
        }
    }

    private func makeSampleBuffer(
        data: Data,
        format: CMVideoFormatDescription,
        sequence: UInt64,
        isKeyFrame: Bool
    ) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(
                value: Int64(clamping: sequence),
                timescale: 30
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        setSampleAttachments(sampleBuffer, isKeyFrame: isKeyFrame)
        return sampleBuffer
    }

    private func setSampleAttachments(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0,
        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else { return }

        let dictionary = Unmanaged<CFMutableDictionary>
            .fromOpaque(rawDictionary)
            .takeUnretainedValue()
        let displayKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
        let trueValue = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(dictionary, displayKey, trueValue)

        if !isKeyFrame {
            let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            CFDictionarySetValue(dictionary, notSyncKey, trueValue)
        }
    }
}

extension VideoDisplayController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        // SidecarBridge is a silent screen viewer. It does not provide
        // persistent audio playback while its video is in Picture in Picture.
        true
    }
}

extension VideoDisplayController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = nil
        isStartingPictureInPicture = false
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = nil
        isStartingPictureInPicture = false
        publishPictureInPictureState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        pictureInPictureStartWatchdog?.cancel()
        pictureInPictureStartWatchdog = nil
        isStartingPictureInPicture = false
        publishPictureInPictureState()
        onPictureInPictureError?("Picture in Picture failed: \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

struct VideoDisplaySurface: UIViewRepresentable {
    let controller: VideoDisplayController

    func makeUIView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: VideoDisplayView, context: Context) {
        controller.attach(uiView)
    }
}

final class VideoDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }
}
