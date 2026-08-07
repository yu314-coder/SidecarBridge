import CryptoKit
import Foundation

enum SecureChannelRole {
    case client
    case server
}

/// A compact, bidirectional AEAD record layer shared by direct LAN and nearby
/// P2P transports. Direction-specific keys and counters prevent reflection,
/// nonce reuse, and replay without transmitting a random nonce per packet.
final class SecurePacketSession {
    static let marker: UInt8 = 0xE1
    static let envelopeOverhead = 1 + 1 + 1 + 8 + 16
    private static let replayWindowWidth: UInt64 = 64

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var highestReceivedCounter: UInt64?
    private var receivedCounterWindow: UInt64 = 0

    private init(
        sendKey: SymmetricKey,
        receiveKey: SymmetricKey,
        sendDirection: UInt8,
        receiveDirection: UInt8
    ) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.sendDirection = sendDirection
        self.receiveDirection = receiveDirection
    }

    static func keyAgreement(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        clientPublicKey: Data,
        serverPublicKey: Data,
        role: SecureChannelRole,
        context: String
    ) throws -> SecurePacketSession {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var salt = Data("\(context)\u{0}".utf8)
        appendLengthPrefixed(clientPublicKey, to: &salt)
        appendLengthPrefixed(serverPublicKey, to: &salt)
        let clientToServer = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("client-to-server".utf8),
            outputByteCount: 32
        )
        let serverToClient = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("server-to-client".utf8),
            outputByteCount: 32
        )
        switch role {
        case .client:
            return SecurePacketSession(
                sendKey: clientToServer,
                receiveKey: serverToClient,
                sendDirection: 1,
                receiveDirection: 2
            )
        case .server:
            return SecurePacketSession(
                sendKey: serverToClient,
                receiveKey: clientToServer,
                sendDirection: 2,
                receiveDirection: 1
            )
        }
    }

    func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard sendCounter < UInt64.max else { throw SecurePacketError.counterExhausted }

        let counter = sendCounter
        sendCounter += 1
        let header = Self.header(direction: sendDirection, counter: counter)
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: sendDirection, counter: counter))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: sendKey,
            nonce: nonce,
            authenticating: Self.authenticatedData(header: header)
        )
        var envelope = header
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    func open(_ envelope: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard envelope.count >= Self.envelopeOverhead,
              envelope[envelope.startIndex] == Self.marker,
              envelope[envelope.startIndex + 1] == UInt8(LANWire.securityProtocolVersion),
              envelope[envelope.startIndex + 2] == receiveDirection else {
            throw SecurePacketError.invalidEnvelope
        }
        let counterStart = envelope.startIndex + 3
        let counterEnd = counterStart + 8
        let counter = envelope[counterStart..<counterEnd].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard canAccept(counter) else { throw SecurePacketError.replayedPacket }

        let tagStart = envelope.endIndex - 16
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: receiveDirection, counter: counter))
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: envelope[counterEnd..<tagStart],
            tag: envelope[tagStart..<envelope.endIndex]
        )
        let plaintext = try ChaChaPoly.open(
            box,
            using: receiveKey,
            authenticating: Self.authenticatedData(
                header: Data(envelope[envelope.startIndex..<counterEnd])
            )
        )
        markAccepted(counter)
        return plaintext
    }

    static func isEnvelope(_ data: Data) -> Bool {
        data.count >= envelopeOverhead && data.first == marker
    }

    private func canAccept(_ counter: UInt64) -> Bool {
        guard let highestReceivedCounter else { return true }
        if counter > highestReceivedCounter { return true }
        let distance = highestReceivedCounter - counter
        guard distance < Self.replayWindowWidth else { return false }
        return receivedCounterWindow & (UInt64(1) << distance) == 0
    }

    private func markAccepted(_ counter: UInt64) {
        guard let highest = highestReceivedCounter else {
            highestReceivedCounter = counter
            receivedCounterWindow = 1
            return
        }
        if counter > highest {
            let distance = counter - highest
            receivedCounterWindow = distance >= Self.replayWindowWidth
                ? 1
                : (receivedCounterWindow << distance) | 1
            highestReceivedCounter = counter
        } else {
            receivedCounterWindow |= UInt64(1) << (highest - counter)
        }
    }

    private static func header(direction: UInt8, counter: UInt64) -> Data {
        var result = Data([marker, UInt8(LANWire.securityProtocolVersion), direction])
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { result.append(contentsOf: $0) }
        return result
    }

    private static func nonce(direction: UInt8, counter: UInt64) -> Data {
        var result = Data([0, 0, 0, direction])
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { result.append(contentsOf: $0) }
        return result
    }

    private static func authenticatedData(header: Data) -> Data {
        var result = Data("SidecarBridge-secure-packet-v3\u{0}".utf8)
        result.append(header)
        return result
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    enum SecurePacketError: LocalizedError, Equatable {
        case invalidEnvelope
        case replayedPacket
        case counterExhausted

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope:
                return "The encrypted connection sent an invalid packet."
            case .replayedPacket:
                return "The encrypted connection repeated an old packet."
            case .counterExhausted:
                return "The encrypted connection must be re-established."
            }
        }
    }
}

struct LANHandshake: Codable {
    var protocolVersion: Int? = nil
    let deviceName: String
    let publicKey: Data
    var deviceID: String? = nil
    var deviceKind: String? = nil
    var macID: String? = nil
    var authNonce: Data? = nil
    var requiresPairingCode: Bool? = nil
}

enum LANWire {
    static let securityProtocolVersion = 3
    static let clientHello: UInt8 = 0xA1
    static let serverHello: UInt8 = 0xA2
    static let encryptedPacket: UInt8 = 0xA3
    static let maximumPayloadSize = 12 * 1024 * 1024

    static func handshake(_ value: LANHandshake, marker: UInt8) throws -> Data {
        var payload = Data([marker])
        payload.append(try JSONEncoder().encode(value))
        return framed(payload)
    }

    static func encrypted(_ packet: Data, session: SecurePacketSession) throws -> Data {
        var payload = Data([encryptedPacket])
        payload.append(try session.seal(packet))
        return framed(payload)
    }

    static func decrypt(_ payload: Data, session: SecurePacketSession) throws -> Data {
        guard payload.first == encryptedPacket else { throw LANError.invalidMarker }
        return try session.open(Data(payload.dropFirst()))
    }

    static func decodeHandshake(_ payload: Data, marker: UInt8) throws -> LANHandshake {
        guard payload.first == marker else { throw LANError.invalidMarker }
        let handshake = try JSONDecoder().decode(LANHandshake.self, from: payload.dropFirst())
        guard handshake.protocolVersion == securityProtocolVersion else {
            throw LANError.unsupportedSecurityProtocol
        }
        guard handshake.publicKey.count == 32,
              (1...128).contains(handshake.deviceName.utf8.count) else {
            throw LANError.invalidHandshake
        }
        if marker == clientHello {
            let identity = BridgePeerIdentity(
                deviceID: handshake.deviceID ?? "",
                deviceName: handshake.deviceName,
                deviceKind: handshake.deviceKind ?? ""
            )
            guard identity.isValidForAuthentication else { throw LANError.invalidHandshake }
        } else if marker == serverHello {
            guard let macID = handshake.macID,
                  (1...128).contains(macID.utf8.count),
                  handshake.authNonce?.count == 32 else {
                throw LANError.invalidHandshake
            }
        }
        return handshake
    }

    static func secureSession(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        clientPublicKey: Data,
        serverPublicKey: Data,
        role: SecureChannelRole
    ) throws -> SecurePacketSession {
        try SecurePacketSession.keyAgreement(
            privateKey: privateKey,
            peerPublicKey: peerPublicKey,
            clientPublicKey: clientPublicKey,
            serverPublicKey: serverPublicKey,
            role: role,
            context: "SidecarBridge-LAN-v3"
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
        case invalidHandshake
        case unsupportedSecurityProtocol
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: return "Could not encrypt the local connection."
            case .invalidLength: return "The local connection sent an invalid packet length."
            case .invalidMarker: return "The local connection sent an invalid packet type."
            case .invalidHandshake: return "The local connection sent malformed authentication metadata."
            case .unsupportedSecurityProtocol:
                return "The other device uses an older insecure connection protocol. Update SidecarBridge on both devices."
            case .authenticationFailed:
                return "The Mac could not be authenticated. Disconnecting to protect your input."
            }
        }
    }
}
