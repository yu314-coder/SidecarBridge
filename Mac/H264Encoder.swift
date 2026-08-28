import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264Encoder {
    enum EncoderError: LocalizedError {
        case createFailed(OSStatus)
        case configureFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .createFailed(let status):
                return "Could not create the hardware H.264 encoder (\(status))."
            case .configureFailed(let status):
                return "Could not configure the hardware H.264 encoder (\(status))."
            }
        }
    }

    var onFrame: ((VideoFrame) -> Void)?

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var frameRate = 30
    private var targetBitrate = 0
    private var nextSequence: UInt64 = 0
    // A forced IDR request must survive a VideoToolbox submission that is
    // dropped under memory pressure. Clearing the flag at submission time
    // turns the next successful picture into the periodic one-second IDR,
    // which looks like a 1-FPS stream while the input channel still works.
    private let keyFrameLock = NSLock()
    private var forceNextKeyFrame = false
    private var keyFrameRequestGeneration: UInt64 = 0
    private var keyFrameSubmissionGeneration: UInt64?
    // VideoToolbox is asynchronous. Do not hand it an unbounded number of
    // frames while the Mac is paging or the hardware encoder is catching up;
    // dropping at this boundary keeps the capture source close to the live
    // edge instead of turning low memory into seconds of stale video.
    private let inFlightLock = NSLock()
    private var inFlightByGeneration: [UInt64: Int] = [:]
    // Keep a small hardware pipeline so a single slow VideoToolbox callback
    // cannot turn a 60-FPS capture into one completed frame per second. The
    // surface/bitrate profile is lowered under pressure; the cadence itself
    // is not intentionally lowered.
    private var maximumInFlightFrames = 6
    // VideoToolbox can finish an encode callback after a compression session
    // has been invalidated. A foreground capture rebuild replaces the session
    // while the old callback is still in flight; fence callbacks by generation
    // so a pre-background sample can never be emitted by the new stream.
    private var sessionGeneration: UInt64 = 0

    func start(
        width: Int,
        height: Int,
        frameRate: Int = 30,
        targetBitrate: Int? = nil,
        resetSequence: Bool = true
    ) throws {
        stop()
        sessionGeneration &+= 1
        self.width = width
        self.height = height
        self.frameRate = frameRate
        if resetSequence {
            nextSequence = 0
        }

        var session: VTCompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if status != noErr {
            // Older Intel encoders may not expose the low-latency selector.
            // Preserve hardware compatibility while retaining the real-time
            // properties configured below.
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { throw EncoderError.createFailed(status) }
        self.session = session

        // Keep enough bits for fine text at the larger iPad sizes while
        // bounding the direct stream so a transient Wi-Fi dip does not create
        // an unbounded TCP backlog. The value is bits per second; VideoToolbox
        // receives the corresponding byte-per-second data-rate limit below.
        let bitrate = targetBitrate ?? min(24_000_000, max(12_000_000, width * height * 6))
        self.targetBitrate = bitrate
        // Periodic IDRs are a recovery fallback, not the normal frame-rate
        // mechanism. One per second leaves the hardware encoder focused on
        // P-frames at 90/120 FPS; the transport requests an immediate IDR when
        // it detects a gap or a decoder reset.
        let keyFrameInterval = max(15, frameRate)
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyFrameInterval)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray)
        ]
        for (key, value) in settings {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                stop()
                throw EncoderError.configureFailed(result)
            }
        }
        // Keep the encoder from buffering frames internally. Some legacy
        // encoders do not support this hint, so it is intentionally optional.
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: 0)
        )
        // The viewer is interactive screen content rather than an archival
        // encode. Prefer a frame that is ready now over a slightly better
        // frame that makes the input feel frozen while the Mac is paging.
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue
        )
        if #available(macOS 15.0, *) {
            _ = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_SuggestedLookAheadFrameCount,
                value: NSNumber(value: 0)
            )
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            stop()
            throw EncoderError.configureFailed(prepareStatus)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        let generation = sessionGeneration
        guard reserveEncodeSlot(for: generation) else { return }
        let keyFrameSubmissionGeneration = beginKeyFrameSubmission()
        let frameProperties: CFDictionary?
        if keyFrameSubmissionGeneration != nil {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
            ] as CFDictionary
        } else {
            frameProperties = nil
        }
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            frameProperties: frameProperties,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.releaseEncodeSlot(for: generation)
            guard let self,
                  self.sessionGeneration == generation else { return }

            let dropped = status != noErr || infoFlags.contains(.frameDropped)
            var emittedKeyFrame = false
            if !dropped,
               let sampleBuffer,
               CMSampleBufferDataIsReady(sampleBuffer) {
                // Forward every encoded sample. The previous boolean
                // short-circuit invoked `emit` only for sync samples, so the
                // transport received the periodic IDR (about one per second)
                // while VideoToolbox was actually encoding the intervening
                // P-frames at 50–60 FPS. Keep the sync result only for
                // completing a forced-keyframe request; it must not gate
                // normal frame delivery.
                let isKeyFrame = self.isSyncSample(sampleBuffer)
                let emitted = autoreleasepool {
                    self.emit(sampleBuffer)
                }
                emittedKeyFrame = isKeyFrame && emitted
            }
            if let keyFrameSubmissionGeneration {
                self.finishKeyFrameSubmission(
                    keyFrameSubmissionGeneration,
                    succeeded: emittedKeyFrame
                )
            }
        }
        if status != noErr {
            // A failed submission does not get a completion callback, so
            // return its slot immediately. The next accepted sample can then
            // recover without waiting for a timeout.
            releaseEncodeSlot(for: generation)
            if let keyFrameSubmissionGeneration {
                finishKeyFrameSubmission(keyFrameSubmissionGeneration, succeeded: false)
            }
        }
    }

    /// Claims one forced-IDR submission without losing the request if the
    /// encoder drops that submission. Only one frame at a time is marked as
    /// forced; otherwise a slow encoder could turn one request into a burst
    /// of full IDRs and make memory pressure worse.
    private func beginKeyFrameSubmission() -> UInt64? {
        keyFrameLock.lock()
        defer { keyFrameLock.unlock() }
        guard forceNextKeyFrame, keyFrameSubmissionGeneration == nil else { return nil }
        let generation = keyFrameRequestGeneration
        keyFrameSubmissionGeneration = generation
        return generation
    }

    private func finishKeyFrameSubmission(_ generation: UInt64, succeeded: Bool) {
        keyFrameLock.lock()
        defer { keyFrameLock.unlock() }
        guard keyFrameSubmissionGeneration == generation else { return }
        keyFrameSubmissionGeneration = nil
        if succeeded, generation == keyFrameRequestGeneration {
            forceNextKeyFrame = false
        } else {
            // Keep the request armed after a dropped/invalid output, and also
            // preserve a newer request that arrived while this frame was in
            // flight. The next accepted frame will carry the IDR marker.
            forceNextKeyFrame = true
        }
    }

    private func reserveEncodeSlot(for generation: UInt64) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        let current = inFlightByGeneration[generation, default: 0]
        guard current < maximumInFlightFrames else { return false }
        inFlightByGeneration[generation] = current + 1
        return true
    }

    private func releaseEncodeSlot(for generation: UInt64) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        guard let current = inFlightByGeneration[generation] else { return }
        if current <= 1 {
            inFlightByGeneration.removeValue(forKey: generation)
        } else {
            inFlightByGeneration[generation] = current - 1
        }
    }

    func requestKeyFrame() {
        keyFrameLock.lock()
        // Coalesce requests while an IDR is already pending. Repeated decoder
        // notifications during one pressure stall must not turn recovery into
        // a stream of back-to-back full keyframes.
        if !forceNextKeyFrame {
            keyFrameRequestGeneration &+= 1
            forceNextKeyFrame = true
        }
        keyFrameLock.unlock()
    }

    /// Keep VideoToolbox from retaining several full IOSurfaces while macOS
    /// is under pressure. This is transport-independent: control packets can
    /// remain responsive even if the display encoder is temporarily slower
    /// than the requested cadence.
    func setMemoryPressure(_ level: StreamMemoryPressureLevel) {
        inFlightLock.lock()
        maximumInFlightFrames = switch level {
        case .normal:
            // A 120-FPS nearby stream has only 8.3 ms between capture
            // samples. Keep a slightly deeper, still bounded hardware
            // pipeline so a short VideoToolbox callback hiccup does not
            // collapse the sender to its old ~60-FPS throughput.
            frameRate >= 240 ? 16 : (frameRate >= 120 ? 10 : (frameRate >= 90 ? 8 : 6))
        // The pressure profile reduces dimensions and bitrate. Keep enough
        // asynchronous submissions to sustain the 60-FPS clock while still
        // bounding the number of full IOSurfaces retained by VideoToolbox.
        case .warning: 4
        case .critical: 3
        }
        inFlightLock.unlock()
    }

    /// Updates the timing metadata when the viewer enters or leaves its
    /// background grace period. The capture session remains alive, but the
    /// receiver must see the same cadence that the capture gate is enforcing.
    func setFrameRate(_ frameRate: Int) {
        let safeFrameRate = min(max(frameRate, StreamCadencePolicy.minimumLiveFrameRate), StreamCadencePolicy.maximumFrameRate)
        guard self.frameRate != safeFrameRate else { return }
        self.frameRate = safeFrameRate
        // The receiver's media clock changes with the advertised cadence.
        // Start the new cadence on an IDR so it never has to decode a P-frame
        // whose timing belongs to the previous rate.
        requestKeyFrame()
        if let session {
            _ = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: safeFrameRate)
            )
        }
    }

    /// Adjust the encoder's future output budget while keeping the current
    /// compression session alive. macOS can report system-wide memory
    /// pressure after the stream starts; lowering the bitrate at that point
    /// reduces both VideoToolbox's working set and Network.framework buffers
    /// without tearing down the authenticated input session.
    func setTargetBitrate(_ bitrate: Int) {
        let safeBitrate = min(max(bitrate, 2_000_000), 60_000_000)
        guard targetBitrate != safeBitrate else { return }
        targetBitrate = safeBitrate
        guard let session else { return }
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: safeBitrate)
        )
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: safeBitrate / 8), NSNumber(value: 1)] as CFArray
        )
    }

    func stop() {
        // Invalidate the generation before completing frames. Completion can
        // synchronously or asynchronously invoke the old callback.
        sessionGeneration &+= 1
        guard let session else {
            targetBitrate = 0
            inFlightLock.lock()
            inFlightByGeneration.removeAll(keepingCapacity: false)
            inFlightLock.unlock()
            resetKeyFrameState()
            return
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        targetBitrate = 0
        inFlightLock.lock()
        inFlightByGeneration.removeAll(keepingCapacity: false)
        inFlightLock.unlock()
        resetKeyFrameState()
    }

    private func resetKeyFrameState() {
        keyFrameLock.lock()
        forceNextKeyFrame = false
        keyFrameRequestGeneration = 0
        keyFrameSubmissionGeneration = nil
        keyFrameLock.unlock()
    }

    @discardableResult
    private func emit(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return false }
        var sampleData = Data(count: byteCount)
        let copyStatus = sampleData.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return false }

        let isKeyFrame = isSyncSample(sampleBuffer)
        let parameterSets = isKeyFrame ? h264ParameterSets(from: sampleBuffer) : []
        guard !isKeyFrame || parameterSets.count >= 2 else { return false }

        nextSequence &+= 1
        onFrame?(VideoFrame(
            sequence: nextSequence,
            width: width,
            height: height,
            frameRate: frameRate,
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets,
            sampleData: sampleData
        ))
        return true
    }

    private func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ), CFArrayGetCount(attachments) > 0,
        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) else { return true }

        let dictionary = Unmanaged<CFDictionary>
            .fromOpaque(rawDictionary)
            .takeUnretainedValue()
        let notSyncKey = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        return !CFDictionaryContainsKey(dictionary, notSyncKey)
    }

    private func h264ParameterSets(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return [] }
        var result: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            var headerLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerLength
            )
            guard status == noErr, let pointer, size > 0 else { return [] }
            result.append(Data(bytes: pointer, count: size))
        }
        return result
    }
}
