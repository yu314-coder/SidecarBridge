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
    private var nextSequence: UInt64 = 0

    func start(
        width: Int,
        height: Int,
        frameRate: Int = 30,
        targetBitrate: Int? = nil
    ) throws {
        stop()
        self.width = width
        self.height = height
        self.frameRate = frameRate
        nextSequence = 0

        var session: VTCompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let status = VTCompressionSessionCreate(
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
        guard status == noErr, let session else { throw EncoderError.createFailed(status) }
        self.session = session

        let bitrate = targetBitrate ?? min(16_000_000, max(8_000_000, width * height * 7 / 2))
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 15)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0.5)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate * 3 / 16), NSNumber(value: 1)] as CFArray)
        ]
        for (key, value) in settings {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                stop()
                throw EncoderError.configureFailed(result)
            }
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            stop()
            throw EncoderError.configureFailed(prepareStatus)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        var flags = VTEncodeInfoFlags()
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard status == noErr,
                  !infoFlags.contains(.frameDropped),
                  let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer) else { return }
            self?.emit(sampleBuffer)
        }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return }
        var sampleData = Data(count: byteCount)
        let copyStatus = sampleData.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let isKeyFrame = isSyncSample(sampleBuffer)
        let parameterSets = isKeyFrame ? h264ParameterSets(from: sampleBuffer) : []
        guard !isKeyFrame || parameterSets.count >= 2 else { return }

        nextSequence &+= 1
        onFrame?(VideoFrame(
            sequence: nextSequence,
            width: width,
            height: height,
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets,
            sampleData: sampleData
        ))
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
