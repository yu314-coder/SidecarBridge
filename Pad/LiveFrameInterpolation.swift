import AVFoundation
import QuartzCore
import UIKit
import VideoToolbox

/// Experimental foreground-only player. H.264 is decoded once, then pairs
/// of decoded frames are processed off the main actor. The ordinary player
/// remains the fallback for PiP, unsupported formats and processor failures.
@MainActor
final class LiveFrameInterpolation: NSObject {
    var onSample: ((CMSampleBuffer) -> Bool)?
    var onStatus: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var onRecoveryNeeded: (() -> Void)?
    var refreshRate = 60
    private var decoder = InterpolationDecoder()
    private var processorStorage: AnyObject?
    private var generation = 0
    private var failed = false
    private var previous: DecodedInterpolationFrame?
    private var latest: DecodedInterpolationFrame?
    private var processing = false
    private var task: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var scheduled: [(due: Double, frame: DecodedInterpolationFrame, generated: Bool)] = []
    private var lastStatus = ""
    private var windowStart = CACurrentMediaTime()
    private var outputs = 0
    private var generatedOutputs = 0
    private var processingMS = 0.0
    private var outputIntervals: [Double] = []
    private var lastOutputTime: Double?
    private var lastPresentedPTS: CMTime?
    private var coolingUntil = 0.0
    private var waitingForDecoderKeyFrame = false
    private var decoderRecoveryCount = 0

    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        // An in-flight processor owns its old decoder/frames until completion.
        // Generation checks prevent it from publishing into the new session.
        decoder = InterpolationDecoder()
        processorStorage = nil
        previous = nil
        latest = nil
        processing = false
        failed = false
        scheduled.removeAll()
        displayLink?.invalidate()
        displayLink = nil
        outputs = 0
        generatedOutputs = 0
        outputIntervals.removeAll()
        lastOutputTime = nil
        lastPresentedPTS = nil
        coolingUntil = 0
        waitingForDecoderKeyFrame = false
        decoderRecoveryCount = 0
        windowStart = CACurrentMediaTime()
    }

    /// False means this sample should also follow the unchanged compressed
    /// path. During automatic decoder recovery, dependent P-frames are held
    /// back until a fresh keyframe can seed both display paths safely.
    func enqueue(_ sample: CMSampleBuffer, isKeyFrame: Bool) -> Bool {
        guard !failed else { return false }
        #if targetEnvironment(simulator)
        status("Requires a physical device; using original video")
        return false
        #else
        guard #available(iOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            status("Unsupported device/OS; using original video")
            return false
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let limits = interpolationLimits()
        guard FrameInterpolationPolicy.supportsDimensions(
            width: Int(size.width), height: Int(size.height),
            maximumDimension: limits.maximumDimension,
            maximumPixelCount: limits.maximumPixelCount
        ) else {
            let megapixels = Double(limits.maximumPixelCount) / 1_000_000
            status("Original video — \(size.width)×\(size.height) exceeds this device's interpolation limit (\(limits.maximumDimension) px / \(String(format: "%.1f", megapixels)) MP)")
            return false
        }
        let mirrorKeyFrameToOriginalPlayer = waitingForDecoderKeyFrame && isKeyFrame
        if waitingForDecoderKeyFrame {
            // A P-frame cannot seed either decoder after an overload. Keep the
            // last good image visible while the Mac supplies the requested IDR.
            guard isKeyFrame else { return true }
            decoder = InterpolationDecoder()
            waitingForDecoderKeyFrame = false
            status("Fresh keyframe received — interpolation recovering automatically")
        }
        if processorStorage == nil {
            processorStorage = LiveInterpolationProcessor()
            status("Preparing live interpolation at \(size.width)×\(size.height)…")
        }
        startDisplayLink()
        let epoch = generation
        let accepted = decoder.submit(sample) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                switch result {
                case .success(let frame): self.receive(frame)
                case .failure: self.recoverDecoder()
                }
            }
        }
        guard accepted else {
            recoverDecoder()
            return true
        }
        // Mirror the first recovery IDR through AVSampleBufferDisplayLayer so
        // the ordinary video path has a valid dependency root while the Metal
        // processor resumes. Subsequent frames remain on one path only.
        return !mirrorKeyFrameToOriginalPlayer
        #endif
    }

    private func interpolationLimits() -> (maximumDimension: Int, maximumPixelCount: Int) {
        #if !targetEnvironment(simulator)
        if #available(iOS 27.0, *) {
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration
                .maximumDimension(forSpatialScaleFactor: 1)
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration
                .maximumPixelCount(forSpatialScaleFactor: 1)
            if let maximumDimension, let maximumPixelCount,
               maximumDimension > 0, maximumPixelCount > 0 {
                return (maximumDimension, maximumPixelCount)
            }
        }
        #endif
        // The capability-query API arrived in iOS 27. Keep the documented
        // conservative bound on iOS 26 instead of risking a processor failure.
        return (FrameInterpolationPolicy.legacyMaximumDimension,
                FrameInterpolationPolicy.legacyMaximumPixelCount)
    }

    private func recoverDecoder() {
        guard !waitingForDecoderKeyFrame else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        decoder = InterpolationDecoder()
        processorStorage = nil
        previous = nil
        latest = nil
        processing = false
        scheduled.removeAll(keepingCapacity: true)
        lastPresentedPTS = nil
        coolingUntil = CACurrentMediaTime() + 0.25
        waitingForDecoderKeyFrame = true
        decoderRecoveryCount += 1
        status("Decoder caught up automatically · requesting fresh keyframe (recovery \(decoderRecoveryCount))")
        onRecoveryNeeded?()
    }

    private func receive(_ frame: DecodedInterpolationFrame) {
        // One active pair plus one newest decoded frame, never an unbounded
        // queue. Dropping decoded images doesn't break H.264 dependencies.
        latest = frame
        if processing {
            // In particular, keep native video moving while Apple's ML
            // model is being loaded on the processor actor.
            present(frame, generated: false)
            previous = frame
        }
        drain()
    }

    private func drain() {
        guard !processing, let current = latest else { return }
        latest = nil
        let prior = previous
        previous = current
        guard let prior else { present(current, generated: false); return }
        let interval = CMTimeGetSeconds(CMTimeSubtract(current.pts, prior.pts))
        let now = CACurrentMediaTime()
        guard now >= coolingUntil,
              now - current.arrival < 0.08,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              FrameInterpolationPolicy.shouldInterpolate(interval: interval, processingTime: 0, refreshRate: refreshRate)
        else {
            present(current, generated: false)
            return
        }
        #if !targetEnvironment(simulator)
        guard #available(iOS 26.0, *), let processor = processorStorage as? LiveInterpolationProcessor else {
            present(current, generated: false)
            return
        }
        processing = true
        let epoch = generation
        task = Task { [weak self] in
            do {
                let result = try await processor.interpolate(previous: prior, current: current)
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.processing = false
                self.processingMS = result.duration * 1000
                let finished = CACurrentMediaTime()
                // Initial ML loading and late processing must never delay the
                // next fresh frame or replay an obsolete pair after resume.
                if self.latest != nil || finished - current.arrival > interval * 1.5 {
                    self.coolingUntil = finished + 1
                    if self.latest == nil { self.present(current, generated: false) }
                } else if FrameInterpolationPolicy.shouldInterpolate(
                    interval: interval, processingTime: result.duration, refreshRate: self.refreshRate
                ) {
                    self.scheduled = [
                        (finished, result.frame, true),
                        (finished + interval / 2, current, false)
                    ]
                } else {
                    self.coolingUntil = finished + 1
                    self.present(current, generated: false)
                }
                self.drain()
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.fail("Interpolation unavailable: \(error.localizedDescription). Original video restored.")
            }
        }
        #endif
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Weak target breaks CADisplayLink's target-retain cycle.
        let link = CADisplayLink(target: WeakInterpolationTick(self), selector: #selector(WeakInterpolationTick.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(refreshRate), preferred: Float(refreshRate))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // At most the newest due frame is submitted per display tick.
        var due: (due: Double, frame: DecodedInterpolationFrame, generated: Bool)?
        while let first = scheduled.first, first.due <= now {
            due = scheduled.removeFirst()
        }
        if let due { present(due.frame, generated: due.generated, clearSchedule: false) }
        if now - windowStart >= 1 {
            let elapsed = now - windowStart
            let slowest = outputIntervals.sorted(by: >)
            let count = max(1, Int(ceil(Double(slowest.count) * 0.01)))
            let mean = slowest.prefix(count).reduce(0, +) / Double(count)
            let low = mean > 0 && outputs > 0 ? Int(1 / mean) : 0
            status("Output \(Int(Double(outputs) / elapsed)) FPS (\(Int(Double(generatedOutputs) / elapsed)) generated) · 1% low \(low) · processing \(String(format: "%.1f", processingMS)) ms. Submission timing, not capture FPS.")
            outputs = 0
            generatedOutputs = 0
            windowStart = now
        }
    }

    private func present(_ frame: DecodedInterpolationFrame, generated: Bool, clearSchedule: Bool = true) {
        if clearSchedule { scheduled.removeAll(keepingCapacity: true) }
        if let lastPresentedPTS, CMTimeCompare(frame.pts, lastPresentedPTS) <= 0 { return }
        guard let sample = frame.sampleBuffer() else { return }
        guard onSample?(sample) == true else { return }
        lastPresentedPTS = frame.pts
        let now = CACurrentMediaTime()
        if let lastOutputTime {
            outputIntervals.append(now - lastOutputTime)
            if outputIntervals.count > 600 { outputIntervals.removeFirst() }
        }
        lastOutputTime = now
        outputs += 1
        if generated { generatedOutputs += 1 }
    }

    private func fail(_ message: String) {
        reset()
        failed = true
        status(message)
        onFailure?()
    }

    private func status(_ value: String) {
        guard value != lastStatus else { return }
        lastStatus = value
        onStatus?(value)
    }
}

@MainActor
private final class WeakInterpolationTick: NSObject {
    weak var owner: LiveFrameInterpolation?
    init(_ owner: LiveFrameInterpolation) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

private struct DecodedInterpolationFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let pts: CMTime
    let arrival: Double

    func sampleBuffer() -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                  formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private enum InterpolationError: Error { case unavailable, decode, allocation }

/// VideoToolbox may complete a decode inline or asynchronously. This gate
/// releases one queue slot and publishes exactly one result in either case.
private final class InterpolationDecodeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let slots: DispatchSemaphore
    private let callback: @Sendable (Result<DecodedInterpolationFrame, Error>) -> Void

    init(slots: DispatchSemaphore,
         callback: @escaping @Sendable (Result<DecodedInterpolationFrame, Error>) -> Void) {
        self.slots = slots
        self.callback = callback
    }

    func finish(_ result: Result<DecodedInterpolationFrame, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        slots.signal()
        callback(result)
    }
}

/// Serial hardware decoder with bounded compressed submissions. No waits on
/// the main/UI thread. On overflow recover via a keyframe, never skip P-frames.
private final class InterpolationDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SidecarBridge.interpolation.decode", qos: .userInitiated)
    // Hardware decode is asynchronous. This bound absorbs a short transport
    // burst without allowing compressed frames to accumulate indefinitely.
    private let slots = DispatchSemaphore(value: 12)
    private var session: VTDecompressionSession?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    @discardableResult
    func submit(_ sample: CMSampleBuffer, completion: @escaping @Sendable (Result<DecodedInterpolationFrame, Error>) -> Void) -> Bool {
        guard slots.wait(timeout: .now()) == .success else { return false }
        let completionGate = InterpolationDecodeCompletion(slots: slots, callback: completion)
        queue.async { [self] in
            if session == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample) else {
                    completionGate.finish(.failure(InterpolationError.decode)); return
                }
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true
                ]
                let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                    decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                    imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
                guard result == noErr, let session else {
                    completionGate.finish(.failure(InterpolationError.decode)); return
                }
                VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            }
            guard let session else {
                completionGate.finish(.failure(InterpolationError.decode)); return
            }
            let result = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: VTDecodeFrameFlags(rawValue: 1 << 0),
                infoFlagsOut: nil
            ) {
                status, _, image, pts, _ in
                guard status == noErr, let image else {
                    completionGate.finish(.failure(InterpolationError.decode)); return
                }
                completionGate.finish(.success(DecodedInterpolationFrame(
                    buffer: image, pts: pts, arrival: CACurrentMediaTime()
                )))
            }
            if result != noErr {
                completionGate.finish(.failure(InterpolationError.decode))
            }
        }
        return true
    }
}

#if !targetEnvironment(simulator)
@available(iOS 26.0, *)
private actor LiveInterpolationProcessor {
    private var processor: VTFrameProcessor?
    private var pool: CVPixelBufferPool?

    func interpolate(previous: DecodedInterpolationFrame, current: DecodedInterpolationFrame) async throws
        -> (frame: DecodedInterpolationFrame, duration: Double) {
        let start = CACurrentMediaTime()
        if processor == nil {
            guard let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: CVPixelBufferGetWidth(current.buffer), frameHeight: CVPixelBufferGetHeight(current.buffer),
                numberOfInterpolatedFrames: 1) else { throw InterpolationError.unavailable }
            let instance = VTFrameProcessor()
            try instance.startSession(configuration: config)
            let attributes = config.destinationPixelBufferAttributes as CFDictionary
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess else {
                instance.endSession(); throw InterpolationError.allocation
            }
            processor = instance
        }
        guard let processor, let pool else { throw InterpolationError.unavailable }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &output) == kCVReturnSuccess,
              let output else { throw InterpolationError.allocation }
        let pts = CMTimeAdd(previous.pts, CMTimeMultiplyByFloat64(CMTimeSubtract(current.pts, previous.pts), multiplier: 0.5))
        guard let source = VTFrameProcessorFrame(buffer: current.buffer, presentationTimeStamp: current.pts),
              let reference = VTFrameProcessorFrame(buffer: previous.buffer, presentationTimeStamp: previous.pts),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: pts),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: source, previousFrame: reference,
                    interpolationPhase: [0.5], destinationFrames: [destination]) else { throw InterpolationError.unavailable }
        try await processor.process(parameters: parameters)
        return (DecodedInterpolationFrame(buffer: output, pts: pts, arrival: current.arrival), CACurrentMediaTime() - start)
    }

    deinit { processor?.endSession() }
}
#endif
