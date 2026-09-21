import Foundation
import Network
import CoreGraphics

/// One read task owns all framebuffer state. NWConnection callbacks run off the UI thread.
final class MacScreenSharingSession: @unchecked Sendable {
    private let connection: NWConnection
    private var framebuffer = RFBFramebuffer()
    private var minorVersion = 8
    private let queue = DispatchQueue(label: "io.sidecarbridge.rfb", qos: .userInitiated)

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }
    func cancel() { connection.cancel() }
    func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
    }
    private func read(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 67_108_864 else { throw RFBError.invalid("Screen Sharing message exceeds the size limit.") }
        var result = Data(capacity: count)
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1_048_576)) { data, _, complete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? RFBError.invalid(complete ? "The Mac closed Screen Sharing." : "Screen Sharing stopped receiving data.")) }
                }
            }
            result.append(chunk)
        }
        return result
    }
    func open(password: String) async throws -> (String, Int, Int) {
        connection.start(queue: queue)
        let version = try await read(12)
        guard let banner = String(data: version, encoding: .ascii), banner.hasPrefix("RFB 003."),
              let minor = Int(banner.dropFirst(8).prefix(3)), minor >= 3 else {
            throw RFBError.invalid("This address is not a compatible Mac Screen Sharing server.")
        }
        minorVersion = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        send(Data(String(format: "RFB 003.%03d\n", minorVersion).utf8))
        if minorVersion == 3 {
            let security = try await read(4)
            guard RFBProtocol.u32(security, 0) == 2 else { throw RFBError.invalid("Enable ‘VNC viewers may control screen with password’ on the Mac.") }
        } else {
            let count = Int(try await read(1)[0])
            guard count > 0 else { throw RFBError.invalid(try await reason()) }
            let methods = try await read(count)
            guard methods.contains(2) else { throw RFBError.invalid("Enable ‘VNC viewers may control screen with password’ on the Mac. Apple-account-only authentication is not supported in this mode.") }
            send(Data([2]))
        }
        let challenge = try await read(16)
        send(try RFBProtocol.challengeResponse(challenge, password: password))
        let result = try await read(4)
        guard RFBProtocol.u32(result, 0) == 0 else {
            if minorVersion >= 8 { throw RFBError.invalid(try await reason()) }
            throw RFBError.invalid("The Mac rejected the VNC password. Check it in Screen Sharing settings.")
        }
        send(Data([1])) // Shared desktop: do not disconnect another viewer.
        let header = try await read(24)
        let width = RFBProtocol.u16(header, 0), height = RFBProtocol.u16(header, 2)
        try framebuffer.resize(width: width, height: height)
        let nameLength = Int(RFBProtocol.u32(header, 20))
        guard nameLength <= 4096 else { throw RFBError.invalid("Invalid desktop name length.") }
        let name = String(decoding: try await read(nameLength), as: UTF8.self)
        send(RFBProtocol.pixelFormat)
        send(RFBProtocol.encodings)
        send(RFBProtocol.updateRequest(width: width, height: height, incremental: false))
        return (name, width, height)
    }
    private func reason() async throws -> String {
        let size = Int(RFBProtocol.u32(try await read(4), 0))
        guard size <= 4096 else { throw RFBError.invalid("The Mac returned an invalid error message.") }
        return String(decoding: try await read(size), as: UTF8.self)
    }
    func nextFrame() async throws -> CGImage {
        while true {
            let type = try await read(1)[0]
            switch type {
            case 0:
                let header = try await read(3)
                let count = RFBProtocol.u16(header, 1)
                guard count <= 8192 else { throw RFBError.invalid("Too many framebuffer rectangles.") }
                var resized = false
                for _ in 0..<count {
                    let rectangle = try await read(12)
                    let x = RFBProtocol.u16(rectangle, 0), y = RFBProtocol.u16(rectangle, 2)
                    let width = RFBProtocol.u16(rectangle, 4), height = RFBProtocol.u16(rectangle, 6)
                    let encoding = Int32(bitPattern: RFBProtocol.u32(rectangle, 8))
                    if encoding == -223 {
                        try framebuffer.resize(width: width, height: height)
                        resized = true
                        continue
                    }
                    try framebuffer.validate(x: x, y: y, width: width, height: height)
                    switch encoding {
                    case 0:
                        // Bounded ~64 KB chunks avoid thousands of receive callbacks per frame.
                        let rowsPerChunk = max(1, 65_536 / max(1, width * 4))
                        for row in stride(from: 0, to: height, by: rowsPerChunk) {
                            let rows = min(rowsPerChunk, height - row)
                            let bytes = try await read(width * 4 * rows)
                            try framebuffer.raw(x: x, y: y + row, width: width, height: rows, bytes: bytes)
                        }
                    case 1:
                        let source = try await read(4)
                        try framebuffer.copy(x: x, y: y, width: width, height: height,
                                             sourceX: RFBProtocol.u16(source, 0), sourceY: RFBProtocol.u16(source, 2))
                    default: throw RFBError.invalid("The Mac sent an unsupported screen encoding (\(encoding)).")
                    }
                }
                if count == 0 {
                    try await Task.sleep(nanoseconds: 33_000_000)
                    send(RFBProtocol.updateRequest(width: framebuffer.width, height: framebuffer.height, incremental: true))
                    continue
                }
                guard let provider = CGDataProvider(data: framebuffer.pixels as CFData),
                      let image = CGImage(width: framebuffer.width, height: framebuffer.height,
                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: framebuffer.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                    throw RFBError.invalid("Could not display the Mac framebuffer.")
                }
                // Only one update outstanding; no unbounded frame or decode queue.
                send(RFBProtocol.updateRequest(width: framebuffer.width, height: framebuffer.height, incremental: !resized))
                return image
            case 2: continue // Bell
            case 3:
                let header = try await read(7)
                let count = Int(RFBProtocol.u32(header, 3))
                guard count <= 1_048_576 else { throw RFBError.invalid("The Mac clipboard message is too large.") }
                _ = try await read(count) // No automatic clipboard reads/writes or permission prompts.
            default: throw RFBError.invalid("Unsupported Screen Sharing message (\(type)).")
            }
        }
    }
}
