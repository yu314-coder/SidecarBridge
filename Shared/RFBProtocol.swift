import Foundation
import CommonCrypto

// RFB 3.3/3.7/3.8, RFC 6143. Deliberately advertise only implemented encodings.
enum RFBError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum RFBProtocol {
    static func u16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) << 8 | Int(data[offset + 1])
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + $1]) }
    }
    static func word(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
    static func long(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
    static func challengeResponse(_ challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16, !password.isEmpty, password.utf8.count <= 8,
              password.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            throw RFBError.invalid("Use the VNC password set on the Mac (1–8 ASCII characters), not its login password or SidecarBridge pairing code.")
        }
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.enumerated() {
            key[index] = (0..<8).reduce(UInt8(0)) { ($0 << 1) | ((byte >> $1) & 1) }
        }
        var output = [UInt8](repeating: 0, count: 16)
        var length = 0
        let status = challenge.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                    CCOptions(kCCOptionECBMode), key, key.count, nil,
                    bytes.baseAddress, challenge.count, &output, output.count, &length)
        }
        guard status == kCCSuccess, length == 16 else { throw RFBError.invalid("VNC authentication could not be encoded.") }
        return Data(output)
    }
    // 32-bit little-endian RGBX; CoreGraphics uses the matching byte layout.
    static let pixelFormat = Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0])
    static let encodings = Data([2, 0, 0, 3] + long(1) + long(0) + long(UInt32(bitPattern: -223)))
    static func updateRequest(width: Int, height: Int, incremental: Bool) -> Data {
        Data([3, incremental ? 1 : 0, 0, 0, 0, 0] + word(width) + word(height))
    }
    static func key(_ symbol: UInt32, down: Bool) -> Data {
        Data([4, down ? 1 : 0, 0, 0] + long(symbol))
    }
    static func pointer(x: Int, y: Int, buttons: UInt8) -> Data {
        Data([5, buttons] + word(x) + word(y))
    }
}

struct RFBFramebuffer {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var pixels = Data()

    mutating func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 16_777_216 else {
            throw RFBError.invalid("The Mac requested an unsupported framebuffer size (maximum 16 megapixels).")
        }
        self.width = width; self.height = height
        pixels = Data(count: width * height * 4)
    }
    func validate(x: Int, y: Int, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, width >= 0, height >= 0,
              x <= self.width, y <= self.height,
              width <= self.width - x, height <= self.height - y else {
            throw RFBError.invalid("The Mac sent an invalid framebuffer rectangle.")
        }
    }
    mutating func raw(x: Int, y: Int, width: Int, height: Int, bytes: Data) throws {
        try validate(x: x, y: y, width: width, height: height)
        guard bytes.count == width * height * 4 else { throw RFBError.invalid("Incomplete framebuffer data.") }
        for row in 0..<height {
            let start = ((y + row) * self.width + x) * 4
            pixels.replaceSubrange(start..<(start + width * 4), with: bytes[(row * width * 4)..<((row + 1) * width * 4)])
        }
    }
    mutating func copy(x: Int, y: Int, width: Int, height: Int, sourceX: Int, sourceY: Int) throws {
        try validate(x: x, y: y, width: width, height: height)
        try validate(x: sourceX, y: sourceY, width: width, height: height)
        // Snapshot only the affected rectangle: overlapping scroll copies must not smear.
        var rectangle = Data(capacity: width * height * 4)
        for row in 0..<height {
            let start = ((sourceY + row) * self.width + sourceX) * 4
            rectangle.append(pixels[start..<(start + width * 4)])
        }
        try raw(x: x, y: y, width: width, height: height, bytes: rectangle)
    }
}
