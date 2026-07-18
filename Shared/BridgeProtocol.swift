import Foundation

enum BridgeConstants {
    static let serviceType = "sb-screen"
    static let lanServiceType = "_sb-direct._tcp"
}

enum LocalNetworkAccessState: Equatable {
    case checking
    case granted
    case denied
    case unavailable(String)

    var isGranted: Bool { self == .granted }
    var needsPermission: Bool { self == .denied }
}

enum ControlKind: String, Codable, Equatable {
    case hello
    case trySidecar
    case startFallback
    case stopFallback
    case status
    case input
}

struct ControlMessage: Codable, Equatable {
    let kind: ControlKind
    var detail: String?

    init(_ kind: ControlKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

enum RemoteInputKind: String, Codable, Equatable {
    case pointerMove
    case primaryDown
    case primaryDrag
    case primaryUp
    case primaryClick
    case primaryDoubleClick
    case secondaryClick
    case scroll
    case text
    case key
}

struct RemoteInputEvent: Codable, Equatable {
    let kind: RemoteInputKind
    var sequence: UInt64?
    var x: Double?
    var y: Double?
    var deltaX: Double?
    var deltaY: Double?
    var text: String?
    var key: String?
    var modifiers: [String]?

    static func pointer(x: Double, y: Double) -> Self {
        Self(kind: .pointerMove, sequence: nil, x: x, y: y)
    }

    static func click(secondary: Bool = false, x: Double? = nil, y: Double? = nil) -> Self {
        Self(kind: secondary ? .secondaryClick : .primaryClick, sequence: nil, x: x, y: y)
    }

    static func doubleClick(x: Double? = nil, y: Double? = nil) -> Self {
        Self(kind: .primaryDoubleClick, sequence: nil, x: x, y: y)
    }

    static func primaryDown(x: Double, y: Double) -> Self {
        Self(kind: .primaryDown, sequence: nil, x: x, y: y)
    }

    static func primaryDrag(x: Double, y: Double) -> Self {
        Self(kind: .primaryDrag, sequence: nil, x: x, y: y)
    }

    static func primaryUp(x: Double? = nil, y: Double? = nil) -> Self {
        Self(kind: .primaryUp, sequence: nil, x: x, y: y)
    }

    static func scroll(x: Double, y: Double) -> Self {
        Self(kind: .scroll, sequence: nil, deltaX: x, deltaY: y)
    }

    static func text(_ text: String) -> Self {
        Self(kind: .text, sequence: nil, text: text)
    }

    static func key(_ key: String, modifiers: [String] = []) -> Self {
        Self(kind: .key, sequence: nil, key: key, modifiers: modifiers)
    }
}

extension ControlMessage {
    static func input(_ event: RemoteInputEvent) -> ControlMessage? {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return ControlMessage(.input, detail: json)
    }

    var remoteInputEvent: RemoteInputEvent? {
        guard kind == .input, let detail, let data = detail.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteInputEvent.self, from: data)
    }
}

enum BridgePacket: Equatable {
    case control(ControlMessage)
    case jpeg(Data)
    case video(VideoFrame)
}

struct VideoFrame: Equatable {
    let sequence: UInt64
    let width: Int
    let height: Int
    let isKeyFrame: Bool
    let parameterSets: [Data]
    let sampleData: Data
}

enum PacketCodec {
    private static let controlMarker: UInt8 = 1
    private static let jpegMarker: UInt8 = 2
    private static let videoMarker: UInt8 = 3

    private struct VideoHeader: Codable {
        let sequence: UInt64
        let width: Int
        let height: Int
        let isKeyFrame: Bool
        let parameterSets: [Data]
    }

    static func encode(_ packet: BridgePacket) throws -> Data {
        switch packet {
        case .control(let message):
            var data = Data([controlMarker])
            data.append(try JSONEncoder().encode(message))
            return data
        case .jpeg(let jpeg):
            var data = Data([jpegMarker])
            data.append(jpeg)
            return data
        case .video(let frame):
            let header = try JSONEncoder().encode(VideoHeader(
                sequence: frame.sequence,
                width: frame.width,
                height: frame.height,
                isKeyFrame: frame.isKeyFrame,
                parameterSets: frame.parameterSets
            ))
            guard header.count <= Int(UInt32.max) else { throw PacketError.invalidVideoFrame }
            var data = Data([videoMarker])
            let headerLength = UInt32(header.count).bigEndian
            withUnsafeBytes(of: headerLength) { data.append(contentsOf: $0) }
            data.append(header)
            data.append(frame.sampleData)
            return data
        }
    }

    static func decode(_ data: Data) throws -> BridgePacket {
        guard let marker = data.first else { throw PacketError.empty }
        let payload = data.dropFirst()

        switch marker {
        case controlMarker:
            return .control(try JSONDecoder().decode(ControlMessage.self, from: payload))
        case jpegMarker:
            guard !payload.isEmpty else { throw PacketError.emptyFrame }
            return .jpeg(Data(payload))
        case videoMarker:
            let videoData = Data(payload)
            guard videoData.count >= 5 else { throw PacketError.invalidVideoFrame }
            let headerLength = videoData.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let headerEnd = 4 + Int(headerLength)
            guard headerLength > 0, videoData.count > headerEnd else { throw PacketError.invalidVideoFrame }
            let header = try JSONDecoder().decode(VideoHeader.self, from: videoData[4..<headerEnd])
            guard header.width > 0, header.height > 0 else { throw PacketError.invalidVideoFrame }
            return .video(VideoFrame(
                sequence: header.sequence,
                width: header.width,
                height: header.height,
                isKeyFrame: header.isKeyFrame,
                parameterSets: header.parameterSets,
                sampleData: Data(videoData[headerEnd...])
            ))
        default:
            throw PacketError.unknownMarker(marker)
        }
    }

    enum PacketError: LocalizedError, Equatable {
        case empty
        case emptyFrame
        case invalidVideoFrame
        case unknownMarker(UInt8)

        var errorDescription: String? {
            switch self {
            case .empty: return "The packet is empty."
            case .emptyFrame: return "The frame has no image data."
            case .invalidVideoFrame: return "The video frame is malformed."
            case .unknownMarker(let marker): return "Unknown packet marker: \(marker)."
            }
        }
    }
}
