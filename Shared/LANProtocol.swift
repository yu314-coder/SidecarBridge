import CryptoKit
import Foundation

struct LANHandshake: Codable {
    let deviceName: String
    let publicKey: Data
    var deviceID: String? = nil
    var deviceKind: String? = nil
}

enum LANWire {
    static let clientHello: UInt8 = 0xA1
    static let serverHello: UInt8 = 0xA2
    static let encryptedPacket: UInt8 = 0xA3
    static let maximumPayloadSize = 12 * 1024 * 1024

    static func handshake(_ value: LANHandshake, marker: UInt8) throws -> Data {
        var payload = Data([marker])
        payload.append(try JSONEncoder().encode(value))
        return framed(payload)
    }

    static func encrypted(_ packet: Data, key: SymmetricKey) throws -> Data {
        let sealed = try ChaChaPoly.seal(packet, using: key)
        var payload = Data([encryptedPacket])
        payload.append(sealed.combined)
        return framed(payload)
    }

    static func decrypt(_ payload: Data, key: SymmetricKey) throws -> Data {
        guard payload.first == encryptedPacket else { throw LANError.invalidMarker }
        let box = try ChaChaPoly.SealedBox(combined: Data(payload.dropFirst()))
        return try ChaChaPoly.open(box, using: key)
    }

    static func decodeHandshake(_ payload: Data, marker: UInt8) throws -> LANHandshake {
        guard payload.first == marker else { throw LANError.invalidMarker }
        return try JSONDecoder().decode(LANHandshake.self, from: payload.dropFirst())
    }

    static func sessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var salt = Data("SidecarBridge-LAN-v1".utf8)
        salt.append(clientPublicKey)
        salt.append(serverPublicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("screen-and-input".utf8),
            outputByteCount: 32
        )
    }

    static func framed(_ payload: Data) -> Data {
        var result = Data()
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    static func takeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        var cursor = buffer.startIndex

        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let headerEnd = buffer.index(cursor, offsetBy: 4)
            let length = buffer[cursor..<headerEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= maximumPayloadSize else { throw LANError.invalidLength }
            guard buffer.distance(from: headerEnd, to: buffer.endIndex) >= Int(length) else { break }

            let payloadEnd = buffer.index(headerEnd, offsetBy: Int(length))
            frames.append(Data(buffer[headerEnd..<payloadEnd]))
            cursor = payloadEnd
        }

        if cursor != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<cursor)
        }
        return frames
    }

    enum LANError: LocalizedError {
        case encryptionFailed
        case invalidLength
        case invalidMarker

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: return "Could not encrypt the local connection."
            case .invalidLength: return "The local connection sent an invalid packet length."
            case .invalidMarker: return "The local connection sent an invalid packet type."
            }
        }
    }
}
