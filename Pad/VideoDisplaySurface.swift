import AVFoundation
import AVKit
import CoreMedia
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

    var isPictureInPictureActive: Bool {
        pictureInPictureController?.isPictureInPictureActive == true
    }

    var isPictureInPicturePossible: Bool {
        pictureInPictureController?.isPictureInPicturePossible == true
    }

    func attach(_ view: VideoDisplayView) {
        self.view = view
        configurePictureInPicture(for: view.displayLayer)
    }

    @discardableResult
    func enqueue(_ frame: VideoFrame) -> Bool {
        if frame.isKeyFrame, frame.parameterSets.count >= 2, frame.parameterSets != parameterSets {
            parameterSets = frame.parameterSets
            formatDescription = makeFormatDescription(parameterSets: frame.parameterSets)
            needsKeyFrame = formatDescription == nil
            view?.flush()
        }
        guard let formatDescription, !needsKeyFrame || frame.isKeyFrame else { return false }
        guard let sampleBuffer = makeSampleBuffer(
            data: frame.sampleData,
            format: formatDescription,
            sequence: frame.sequence,
            isKeyFrame: frame.isKeyFrame
        ) else { return false }

        if view?.displayLayer.status == .failed {
            view?.flush()
            needsKeyFrame = true
            guard frame.isKeyFrame else { return false }
        }
        guard view?.displayLayer.isReadyForMoreMediaData == true else { return false }
        needsKeyFrame = false
        view?.enqueue(sampleBuffer)
        return true
    }

    func flush() {
        needsKeyFrame = true
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
        guard pictureInPictureController.isPictureInPicturePossible else {
            publishPictureInPictureState()
            onPictureInPictureError?("Picture in Picture is not ready yet. Wait for the live video, then try again.")
            return false
        }
        do {
            try activateBackgroundAudioSession()
            pictureInPictureController.invalidatePlaybackState()
            isStartingPictureInPicture = true
            pictureInPictureController.startPictureInPicture()
            return true
        } catch {
            onPictureInPictureError?("Could not prepare background playback: \(error.localizedDescription)")
            return false
        }
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
        pictureInPictureController?.stopPictureInPicture()
    }

    func setAutomaticBackgroundStart(_ enabled: Bool) {
        automaticBackgroundStartEnabled = enabled
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = enabled
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

        pictureInPicturePossibleObservation = nil
        pictureInPictureController?.stopPictureInPicture()
        isStartingPictureInPicture = false
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticBackgroundStartEnabled
        pictureInPictureDisplayLayer = displayLayer
        pictureInPictureController = controller
        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishPictureInPictureState()
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

    private func activateBackgroundAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try session.setActive(true)
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
        false
    }
}

extension VideoDisplayController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        do {
            try activateBackgroundAudioSession()
        } catch {
            publishPictureInPictureState()
            onPictureInPictureError?("Background audio session failed: \(error.localizedDescription)")
            return
        }
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isStartingPictureInPicture = false
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isStartingPictureInPicture = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        publishPictureInPictureState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isStartingPictureInPicture = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
