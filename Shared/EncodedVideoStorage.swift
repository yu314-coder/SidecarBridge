import CoreMedia
import Foundation

enum EncodedVideoStorage {
    /// The encoder output is immutable. Retain only its compressed block,
    /// not the CMSampleBuffer or a raw capture surface, until Data is released.
    static func data(retaining buffer: CMBlockBuffer) -> Data? {
        let count = CMBlockBufferGetDataLength(buffer)
        guard count > 0 else { return nil }
        var contiguous = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(buffer, atOffset: 0,
            lengthAtOffsetOut: &contiguous, totalLengthOut: &total, dataPointerOut: &pointer)
        if status == kCMBlockBufferNoErr, contiguous == count, total == count, let pointer {
            return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { [buffer] _, _ in
                withExtendedLifetime(buffer) {}
            })
        }
        var result = Data(count: count)
        let copied = result.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: count, destination: bytes.baseAddress!)
        }
        return copied == kCMBlockBufferNoErr ? result : nil
    }
}
