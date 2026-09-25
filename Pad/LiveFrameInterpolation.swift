import AVFoundation
import QuartzCore
import UIKit
import VideoToolbox

struct FrameInterpolationPacingSample {
    let interval: Double
    let generated: Bool
}

/// Pacing statistics for the same bounded set of accepted output intervals.
struct FrameInterpolationPacingMetrics {
    static let minimumSamplesForOnePercentLow = 500

    let validSampleCount: Int
    let averageFPS: Int?
    let generatedFPS: Int?
    let onePercentLowFPS: Int?
    let slowestFrameMilliseconds: Int?

    init(samples: [FrameInterpolationPacingSample]) {
        let valid = samples.filter { $0.interval.isFinite && $0.interval > 0 }
        validSampleCount = valid.count

        let totalDuration = valid.reduce(0.0) { $0 + $1.interval }
        if totalDuration > 0 {
            averageFPS = Int((Double(valid.count) / totalDuration).rounded())
            let generatedCount = valid.reduce(0) { $0 + ($1.generated ? 1 : 0) }
            generatedFPS = Int((Double(generatedCount) / totalDuration).rounded())
            slowestFrameMilliseconds = Int(((valid.map(\.interval).max() ?? 0) * 1_000).rounded())
        } else {
            averageFPS = nil
            generatedFPS = nil
            slowestFrameMilliseconds = nil
        }

        guard valid.count >= Self.minimumSamplesForOnePercentLow else {
            onePercentLowFPS = nil
            return
        }

        let lowestPercentCount = max(1, Int(ceil(Double(valid.count) * 0.01)))
        let slowestIntervals = valid.map(\.interval).sorted(by: >).prefix(lowestPercentCount)
        let slowestDuration = slowestIntervals.reduce(0.0, +)
        onePercentLowFPS = slowestDuration > 0
            ? Int((Double(lowestPercentCount) / slowestDuration).rounded())
            : nil
    }
}

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
    private var sourceFPS = 0
    private var skipReason = "waiting for a second source frame"
    private var displayRefreshFPS = 60
    private var outputIntervals = [FrameInterpolationPacingSample](
        repeating: FrameInterpolationPacingSample(interval: 0, generated: false), count: 600)
    private var outputIntervalCount = 0
    private var nextOutputIntervalIndex = 0
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
        processingMS = 0
        sourceFPS = 0
        skipReason = "waiting for a second source frame"
        displayRefreshFPS = refreshRate
        outputIntervalCount = 0
        nextOutputIntervalIndex = 0
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
            // Presenting a newer source here makes the in-flight midpoint
            // older than the displayed PTS, so it can never be shown. Only
            // bypass processing when model loading has visibly stalled.
            if let lastOutputTime, CACurrentMediaTime() - lastOutputTime > 0.10 {
                present(frame, generated: false)
                previous = frame
                latest = nil
            }
        }
        drain()
    }

    private func drain() {
        guard !processing, let current = latest else { return }
        latest = nil
        let prior = previous
        previous = current
        guard let prior else { presentOrQueueOriginal(current); return }
        let interval = CMTimeGetSeconds(CMTimeSubtract(current.pts, prior.pts))
        let now = CACurrentMediaTime()
        if interval.isFinite, interval > 0 { sourceFPS = Int((1 / interval).rounded()) }
        let thermalState = ProcessInfo.processInfo.thermalState
        if now < coolingUntil {
            skipReason = "brief recovery cooldown"
            presentOrQueueOriginal(current)
            return
        }
        if now - current.arrival >= 0.08 {
            skipReason = "source frame arrived late"
            presentOrQueueOriginal(current)
            return
        }
        if thermalState == .serious || thermalState == .critical {
            skipReason = "paused for thermal pressure"
            presentOrQueueOriginal(current)
            return
        }
        let minimumDisplayRate = interval.isFinite && interval > 0 ? Int(ceil(1.8 / interval)) : 0
        if displayRefreshFPS < minimumDisplayRate {
            skipReason = "display \(displayRefreshFPS) Hz; need \(minimumDisplayRate) Hz for source cadence"
            presentOrQueueOriginal(current)
            return
        }
        guard FrameInterpolationPolicy.shouldInterpolate(
            interval: interval, processingTime: 0, refreshRate: displayRefreshFPS
        ) else {
            skipReason = "unsupported source cadence (\(sourceFPS) FPS)"
            presentOrQueueOriginal(current)
            return
        }
        skipReason = "processing"
        #if !targetEnvironment(simulator)
        guard #available(iOS 26.0, *), let processor = processorStorage as? LiveInterpolationProcessor else {
            presentOrQueueOriginal(current)
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
                if finished - current.arrival > max(0.05, interval * 2.5) ||
                   (self.lastPresentedPTS.map { CMTimeCompare(current.pts, $0) <= 0 } ?? false) {
                    self.coolingUntil = finished + 0.20
                    self.skipReason = "processor result missed the live window"
                    if self.latest == nil { self.presentOrQueueOriginal(current) }
                } else if FrameInterpolationPolicy.shouldInterpolate(
                    interval: interval, processingTime: result.duration, refreshRate: self.displayRefreshFPS
                ) {
                    self.skipReason = "running"
                    if self.scheduled.count >= 4 {
                        // The display is not consuming two frames per pair.
                        // Drop the late experiment and return to the live edge.
                        self.scheduled.removeAll(keepingCapacity: true)
                        self.coolingUntil = finished + 0.20
                        self.skipReason = "display queue fell behind; using live video"
                        self.present(current, generated: false)
                        self.drain()
                        return
                    }
                    // Keep presentation PTS ordered even if another decoded
                    // frame arrived while the GPU processed this pair. The
                    // next pair may process while these two frames display.
                    let displayInterval = 1.0 / Double(max(60, self.refreshRate))
                    let nextDue = self.scheduled.last.map { $0.due + displayInterval } ?? finished
                    let generatedDue = max(finished, nextDue)
                    self.scheduled.append((generatedDue, result.frame, true))
                    self.scheduled.append((generatedDue + displayInterval, current, false))
                } else {
                    self.coolingUntil = finished + 0.20
                    self.skipReason = "processing took \(Int(result.duration * 1000)) ms; over live budget"
                    self.presentOrQueueOriginal(current)
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
        displayRefreshFPS = refreshRate
        // This experimental mode is explicitly enabled by the user. Request
        // the panel's full rate so ProMotion doesn't settle at 60 Hz.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(refreshRate), maximum: Float(refreshRate), preferred: Float(refreshRate))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func presentOrQueueOriginal(_ frame: DecodedInterpolationFrame) {
        guard let last = scheduled.last else {
            present(frame, generated: false)
            return
        }
        if scheduled.count >= 4 {
            scheduled.removeAll(keepingCapacity: true)
            present(frame, generated: false)
            return
        }
        // A rejected pair can arrive while a generated midpoint and its
        // source are waiting for display. Keep their PTS order intact.
        let displayInterval = 1.0 / Double(max(60, refreshRate))
        scheduled.append((max(CACurrentMediaTime(), last.due + displayInterval), frame, false))
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let displayInterval = link.targetTimestamp - link.timestamp
        if displayInterval.isFinite, displayInterval > 0 {
            let observed = Int((1 / displayInterval).rounded())
            if (30...240).contains(observed) { displayRefreshFPS = observed }
        }
        // Submit one frame per display refresh. Removing all overdue frames
        // in one tick used to discard the generated frame before it appeared.
        if let first = scheduled.first, first.due <= now {
            scheduled.removeFirst()
            present(first.frame, generated: first.generated, clearSchedule: false)
        }
        if now - windowStart >= 1 {
            let elapsed = now - windowStart
            let samples = outputIntervalCount == outputIntervals.count
                ? outputIntervals
                : Array(outputIntervals.prefix(outputIntervalCount))
            let metrics = FrameInterpolationPacingMetrics(samples: samples)
            let rollingFPS = metrics.averageFPS.map(String.init) ?? "—"
            let generatedFPS = metrics.generatedFPS.map(String.init) ?? "—"
            let onePercentLow = metrics.onePercentLowFPS.map(String.init)
                ?? "warming \(metrics.validSampleCount)/\(FrameInterpolationPacingMetrics.minimumSamplesForOnePercentLow)"
            let slowestFrame = metrics.slowestFrameMilliseconds.map(String.init) ?? "—"
            status("Now \(Int(Double(outputs) / elapsed)) FPS (\(Int(Double(generatedOutputs) / elapsed)) generated) · rolling \(rollingFPS) FPS (\(generatedFPS) generated) · 1% low \(onePercentLow) · worst \(slowestFrame) ms · display \(displayRefreshFPS) Hz · source \(sourceFPS) FPS · processing \(String(format: "%.1f", processingMS)) ms · \(skipReason)")
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
            let interval = now - lastOutputTime
            if interval.isFinite, interval > 0 {
                outputIntervals[nextOutputIntervalIndex] = FrameInterpolationPacingSample(
                    interval: interval, generated: generated)
                nextOutputIntervalIndex = (nextOutputIntervalIndex + 1) % outputIntervals.count
                outputIntervalCount = min(outputIntervals.count, outputIntervalCount + 1)
            }
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
