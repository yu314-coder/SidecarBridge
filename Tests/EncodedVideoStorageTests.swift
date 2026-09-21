import XCTest
import CoreMedia

final class EncodedVideoStorageTests: XCTestCase {
    private func buffer(_ bytes: Data) throws -> CMBlockBuffer {
        var result: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &result), noErr)
        let value = try XCTUnwrap(result)
        XCTAssertEqual(bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: value,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }, noErr)
        return value
    }

    func testRetainedBytesSurviveOriginalScopeAndCopyOnWrite() throws {
        let expected = Data(repeating: 0x45, count: 65536)
        let data = try autoreleasepool { try XCTUnwrap(EncodedVideoStorage.data(retaining: buffer(expected))) }
        XCTAssertEqual(data, expected)
        var changed = data
        changed[0] = 0
        XCTAssertEqual(data, expected)
        XCTAssertNotEqual(changed, data)
    }

    func testFragmentedBufferCopiesExactBytes() throws {
        let first = try buffer(Data(repeating: 1, count: 2048))
        let second = try buffer(Data(repeating: 2, count: 2048))
        var joined: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 2, flags: 0, blockBufferOut: &joined), noErr)
        let value = try XCTUnwrap(joined)
        for part in [first, second] {
            XCTAssertEqual(CMBlockBufferAppendBufferReference(value, targetBBuf: part, offsetToData: 0, dataLength: 2048, flags: 0), noErr)
        }
        XCTAssertEqual(EncodedVideoStorage.data(retaining: value), Data(repeating: 1, count: 2048) + Data(repeating: 2, count: 2048))
    }

    func testEmptyBufferRejected() throws {
        var empty: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 0, flags: 0, blockBufferOut: &empty), noErr)
        XCTAssertNil(EncodedVideoStorage.data(retaining: try XCTUnwrap(empty)))
    }
}
