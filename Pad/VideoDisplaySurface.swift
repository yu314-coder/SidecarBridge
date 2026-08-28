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
    /// Called when the H.264 decoder sees a missing frame or has to flush its
    /// dependency chain. The Mac responds with an immediate IDR frame.
    var onKeyFrameNeeded: (() -> Void)?

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
    // Keep a head index instead of repeatedly shifting the array with
    // removeFirst(). At 90/120 FPS that shift made the main-actor display
    // path do avoidable work for every sample.
    private var pendingSamplesHead = 0
    private var displayDrainTask: Task<Void, Never>?
    private var displayStallWatchdogTask: Task<Void, Never>?
    private var currentFrameRate = 30
    private var lastReceivedSequence: UInt64?
    private var lastKeyFrameRequestAt: TimeInterval = 0
    // The wire sequence is a transport counter, not a media clock.  It can
    // continue across a background/foreground cadence change (120 -> 60 ->
    // 120), so using sequence/frameRate directly makes presentation timestamps
    // jump backwards and leaves AVSampleBufferDisplayLayer showing a stale
    // image.  Build a local monotonic timeline instead.
    private var nextPresentationTimestamp = CMTime.zero
    private var formatWidth = 0
    private var formatHeight = 0

    /// Keep the decoder close to the live edge while allowing a short burst
    /// during a local render hiccup. H.264 frames are dropped only from the
    /// not-yet-rendered queue; the last rendered image stays visible while the
    /// decoder waits for the next keyframe.
    private var pendingSampleCount: Int { pendingSamples.count - pendingSamplesHead }

    private var maximumPendingSamples: Int {
        StreamCadencePolicy.decoderQueueDepth(for: currentFrameRate)
    }

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
        // SwiftUI may recreate this UIViewRepresentable while the scene is
        // backgrounded, and AVKit can replace its PiP-backed layer during the
        // same handoff. A new layer has no decoder history; accepting a
        // P-frame into it would leave the old image frozen even while input
        // and transport callbacks continue to work. Treat a replacement as
        // a decoder boundary and wait for a fresh IDR.
        let hasExistingLayer = pictureInPictureDisplayLayer != nil
        let displayLayerChanged = pictureInPictureDisplayLayer !== view.displayLayer
        if hasExistingLayer && displayLayerChanged {
            resetDecoderForNewPresentationSurface()
        }
        let hadPendingSamples = pendingSampleCount > 0
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
        currentFrameRate = frame.frameRate
        guard acceptSequence(frame) else { return false }
        if frame.isKeyFrame,
           frame.parameterSets.count >= 2,
           frame.parameterSets != parameterSets ||
           frame.width != formatWidth ||
           frame.height != formatHeight {
            parameterSets = frame.parameterSets
            formatDescription = makeFormatDescription(parameterSets: frame.parameterSets)
            needsKeyFrame = formatDescription == nil
            formatWidth = frame.width
            formatHeight = frame.height
            hasReceivedSampleBuffer = false
            resetDisplayQueue()
        }
        guard let formatDescription, !needsKeyFrame || frame.isKeyFrame else {
            requestKeyFrameIfNeeded()
            return false
        }
        guard let sampleBuffer = makeSampleBuffer(
            data: frame.sampleData,
            format: formatDescription,
            frameRate: frame.frameRate,
            sequence: frame.sequence,
            isKeyFrame: frame.isKeyFrame
        ) else { return false }

        if view?.displayLayer.status == .failed {
            dropPendingSamplesAndAwaitKeyFrame()
            guard frame.isKeyFrame else {
                requestKeyFrameIfNeeded()
                return false
            }
        }

        // H.264 P-frames depend on the preceding frames. Dropping an arbitrary
        // frame whenever AVSampleBufferDisplayLayer is briefly busy breaks the
        // dependency chain and leaves only the periodic keyframes visible
        // (which looked like a hard 4 FPS cap). Keep a short ordered queue and
        // drain it as soon as the display layer is ready.
        if pendingSampleCount >= maximumPendingSamples {
            dropPendingSamplesAndAwaitKeyFrame()
            requestKeyFrameIfNeeded()
            guard frame.isKeyFrame else { return false }
        }
        needsKeyFrame = false
        let wasReadyForPictureInPicture = hasReceivedSampleBuffer
        lastReceivedSequence = frame.sequence
        pendingSamples.append(sampleBuffer)
        hasReceivedSampleBuffer = true
        // This property is KVO-backed in AVKit. Setting it for every video
        // frame needlessly invalidates PiP state and competes with decoding.
        if !wasReadyForPictureInPicture {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = automaticBackgroundStartEnabled
        }
        drainDisplayQueue()
        if !wasReadyForPictureInPicture {
            attemptPendingPictureInPictureStart()
        }
        return true
    }

    /// Feeds the JPEG fallback into the same sample-buffer layer used by the
    /// H.264 path. The foreground viewer can remain a sharp UIImage while the
    /// layer supplies a real PiP content source when the Mac is on the older
    /// or lower-bandwidth transport.
    @discardableResult
    func enqueueJPEG(_ image: UIImage) -> Bool {
        guard let sampleBuffer = makeImageSampleBuffer(image) else { return false }
        if pendingSampleCount >= maximumPendingSamples {
            // JPEG frames are independent, so discard stale fallback frames
            // instead of allowing a suspended PiP layer to grow the queue.
            pendingSamples.removeAll(keepingCapacity: true)
            pendingSamplesHead = 0
        }
        let wasReadyForPictureInPicture = hasReceivedSampleBuffer
        hasReceivedSampleBuffer = true
        pendingSamples.append(sampleBuffer)
        if !wasReadyForPictureInPicture {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = automaticBackgroundStartEnabled
        }
        drainDisplayQueue()
        if !wasReadyForPictureInPicture {
            attemptPendingPictureInPictureStart()
        }
        return true
    }

    func flush() {
        needsKeyFrame = true
        hasReceivedSampleBuffer = false
        resetDisplayQueue()
    }

    /// Reset the sample-buffer decoder before returning from an iPadOS
    /// background transition. The encrypted socket may remain alive and
    /// deliver frames while away, but the old layer/PiP surface is not a
    /// reliable decode target after the scene handoff. Drop queued frames,
    /// rebuild the H.264 format from the next keyframe, and request that IDR
    /// immediately from the Mac.
    func prepareForForegroundResume() {
        resetDecoderForNewPresentationSurface()
        pictureInPictureController?.invalidatePlaybackState()
        requestKeyFrameIfNeeded(force: true)
    }

    private func drainDisplayQueue() {
        guard let view else { return }
        if view.displayLayer.status == .failed {
            dropPendingSamplesAndAwaitKeyFrame()
            requestKeyFrameIfNeeded()
            return
        }
        while pendingSampleCount > 0, view.displayLayer.isReadyForMoreMediaData {
            view.enqueue(pendingSamples[pendingSamplesHead])
            pendingSamplesHead += 1
        }
        if pendingSamplesHead == pendingSamples.count {
            pendingSamples.removeAll(keepingCapacity: true)
            pendingSamplesHead = 0
        }
        guard pendingSampleCount > 0, displayDrainTask == nil else { return }
        armDisplayStallWatchdog()
        displayDrainTask = Task { @MainActor [weak self] in
            // Avoid spinning the main actor while AVSampleBufferDisplayLayer
            // is busy decoding. A 4-ms retry keeps the live edge responsive
            // without creating hundreds of wakeups per second under pressure.
            try? await Task.sleep(for: .milliseconds(4))
            guard let self else { return }
            self.displayDrainTask = nil
            self.drainDisplayQueue()
        }
    }

    private func resetDisplayQueue() {
        displayDrainTask?.cancel()
        displayDrainTask = nil
        displayStallWatchdogTask?.cancel()
        displayStallWatchdogTask = nil
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesHead = 0
        hasReceivedSampleBuffer = false
        lastReceivedSequence = nil
        nextPresentationTimestamp = .zero
        view?.flush()
    }

    private func resetDecoderForNewPresentationSurface() {
        resetDisplayQueue()
        formatDescription = nil
        parameterSets.removeAll(keepingCapacity: true)
        needsKeyFrame = true
        formatWidth = 0
        formatHeight = 0
    }

    private func armDisplayStallWatchdog() {
        guard displayStallWatchdogTask == nil else { return }
        displayStallWatchdogTask = Task { @MainActor [weak self] in
            // Decoder readiness can legitimately dip while iPadOS is
            // reclaiming memory. Flushing after 750 ms repeatedly discarded
            // the H.264 dependency chain and left only periodic IDRs visible
            // (the sender then appeared to be running at ~1 FPS). Give the
            // display layer a longer recovery window and only reset the
            // decoder when it explicitly reports failure.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.displayStallWatchdogTask = nil
            guard self.pendingSampleCount > 0,
                  let view = self.view else { return }
            if view.displayLayer.status == .failed {
                // A decoder can remain non-ready while it drains its internal
                // queue. Do not turn that normal back-pressure into a keyframe
                // recovery loop; only an explicit failed state warrants a
                // dependency reset.
                self.dropPendingSamplesAndAwaitKeyFrame()
                self.requestKeyFrameIfNeeded()
            }
        }
    }

    /// Drops samples which have not reached the display layer yet while
    /// keeping the last rendered image on screen.  A transport hiccup can
    /// leave an H.264 dependency chain incomplete; removing the layer image
    /// here would make that hiccup visible as a distracting black flash.  The next IDR
    /// frame rebuilds the decoder chain, while the already-rendered frame
    /// remains visible until then.
    private func dropPendingSamplesAndAwaitKeyFrame() {
        displayDrainTask?.cancel()
        displayDrainTask = nil
        pendingSamples.removeAll(keepingCapacity: true)
        pendingSamplesHead = 0
        needsKeyFrame = true
        // Reset the decoder's pending dependency chain without removing the
        // image that is already being presented. `flushAndRemoveImage()` is
        // reserved for an explicit disconnect; using it during recovery is
        // the black flash users see when one packet is late or dropped.
        view?.flushDecoderKeepingImage()
    }

    /// A reliable transport can still lose or reorder a video packet while a
    /// connection is being resumed. Never enqueue a P-frame whose dependency
    /// chain is incomplete: AVSampleBufferDisplayLayer would otherwise keep
    /// presenting an old image until the next periodic keyframe. The gap
    /// request is rate-limited so a bad burst does not monopolize the control
    /// channel.
    private func acceptSequence(_ frame: VideoFrame) -> Bool {
        if let lastReceivedSequence {
            guard frame.sequence > lastReceivedSequence else { return false }
            if frame.sequence - lastReceivedSequence > 1 {
                dropPendingSamplesAndAwaitKeyFrame()
                if !frame.isKeyFrame {
                    requestKeyFrameIfNeeded()
                    return false
                }
            }
        }
        return true
    }

    private func requestKeyFrameIfNeeded(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastKeyFrameRequestAt >= 0.25 else { return }
        lastKeyFrameRequestAt = now
        onKeyFrameNeeded?()
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
        frameRate: Int,
        sequence: UInt64,
        isKeyFrame: Bool
    ) -> CMSampleBuffer? {
        guard !data.isEmpty else { return nil }
        // The encrypted receive path already owns an immutable Data buffer.
        // Keep that storage alive through the sample buffer instead of
        // allocating and copying every H.264 payload a second time. This is
        // especially important for 2K/120-FPS streams, where the copy alone
        // can consume a full iPad performance core.
        let storage = data as NSData
        let retainedStorage = Unmanaged.passRetained(storage)
        var customSource = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                Unmanaged<NSData>.fromOpaque(refCon).release()
            },
            refCon: retainedStorage.toOpaque()
        )
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: storage.bytes),
            blockLength: storage.length,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &customSource,
            offsetToData: 0,
            dataLength: storage.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            retainedStorage.release()
            return nil
        }

        let safeFrameRate = min(max(frameRate, 1), StreamCadencePolicy.maximumFrameRate)
        let duration = CMTime(value: 1, timescale: CMTimeScale(safeFrameRate))
        let presentationTimeStamp = nextPresentationTimestamp
        nextPresentationTimestamp = CMTimeAdd(presentationTimeStamp, duration)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
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

    func flushDecoderKeepingImage() {
        displayLayer.flush()
    }
}
