import XCTest
import CryptoKit

final class PacketCodecTests: XCTestCase {
    func testControlRoundTrip() throws {
        let input = ControlMessage(.trySidecar, detail: "Desk iPad")
        let data = try PacketCodec.encode(.control(input))
        XCTAssertEqual(try PacketCodec.decode(data), .control(input))
    }

    func testHeartbeatRoundTrip() throws {
        let heartbeat = ControlMessage(.status, detail: "heartbeat-ping:test-token")
        XCTAssertEqual(
            try PacketCodec.decode(PacketCodec.encode(.control(heartbeat))),
            .control(heartbeat)
        )
    }

    func testJPEGFrameRoundTrip() throws {
        let input = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let data = try PacketCodec.encode(.jpeg(input))
        XCTAssertEqual(try PacketCodec.decode(data), .jpeg(input))
    }

    func testH264FrameRoundTrip() throws {
        let frame = VideoFrame(
            sequence: 99,
            width: 2360,
            height: 1328,
            isKeyFrame: true,
            parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3, 4])],
            sampleData: Data([0, 0, 0, 2, 0x65, 0x88])
        )
        XCTAssertEqual(try PacketCodec.decode(PacketCodec.encode(.video(frame))), .video(frame))
    }

    func testFileTransferPacketRoundTrip() throws {
        let transfer = FileTransferPacket(
            kind: .chunk,
            transferID: UUID(),
            name: "notes.txt",
            totalSize: 4,
            offset: 0,
            payload: Data([1, 2, 3, 4]),
            message: nil
        )
        XCTAssertEqual(try PacketCodec.decode(PacketCodec.encode(.file(transfer))), .file(transfer))
    }

    @MainActor
    func testChunkedFileTransferRoundTrip() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTransfers/\(UUID().uuidString)", isDirectory: true)
        let senderDirectory = root.appendingPathComponent("sender", isDirectory: true)
        let receiverDirectory = root.appendingPathComponent("receiver", isDirectory: true)
        try FileManager.default.createDirectory(at: senderDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = Data((0..<(FileTransferEngine.chunkSize * 2 + 17)).map { UInt8($0 % 251) })
        let source = senderDirectory.appendingPathComponent("sample.bin")
        try original.write(to: source)

        let sender = FileTransferEngine { senderDirectory }
        let receiver = FileTransferEngine { receiverDirectory }
        sender.sendPacket = { receiver.handle($0) }
        receiver.sendPacket = { sender.handle($0) }

        var receivedURL: URL?
        receiver.onReceived = { receivedURL = $0 }
        sender.sendFile(at: source)

        let destination = try XCTUnwrap(receivedURL)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(sender.isBusy)
        XCTAssertFalse(receiver.isBusy)
    }

    func testEmptyPacketRejected() {
        XCTAssertThrowsError(try PacketCodec.decode(Data()))
    }

    func testRemoteInputRoundTrip() throws {
        var input = RemoteInputEvent.key("c", modifiers: ["command"])
        input.sequence = 42
        let message = try XCTUnwrap(ControlMessage.input(input))
        XCTAssertEqual(message.remoteInputEvent, input)
    }

    func testRemoteKeyboardModifiersAreCanonicalAndDoNotLeakUnknownFlags() {
        let input = RemoteInputEvent.key(
            "c",
            modifiers: ["SHIFT", "command", "control", "command", "caps-lock", "tab"]
        )

        XCTAssertEqual(input.modifiers, ["command", "control", "shift"])
    }

    func testRemoteKeyboardTextNeverCarriesShortcutModifiers() throws {
        let input = try XCTUnwrap(RemoteKeyboardInput.event(
            text: "A",
            modifiers: ["command", "shift"]
        ))

        XCTAssertEqual(input.kind, .text)
        XCTAssertEqual(input.text, "A")
        XCTAssertNil(input.modifiers)
    }

    func testRemoteKeyboardSpecialKeyPreservesOnlyCurrentModifiers() throws {
        let input = try XCTUnwrap(RemoteKeyboardInput.event(
            key: "TAB",
            modifiers: ["shift", "unknown", "control"]
        ))

        XCTAssertEqual(input.kind, .key)
        XCTAssertEqual(input.key, "tab")
        XCTAssertEqual(input.modifiers, ["control", "shift"])
    }

    func testRemoteKeyboardKeyFactoryNormalizesCase() {
        XCTAssertEqual(RemoteInputEvent.key("PageUp").key, "pageup")
    }

    func testRemoteDragRoundTrip() throws {
        let inputs = [
            RemoteInputEvent.primaryDown(x: 0.2, y: 0.3),
            RemoteInputEvent.primaryDrag(x: 0.5, y: 0.6),
            RemoteInputEvent.primaryUp(x: 0.7, y: 0.8)
        ]

        for input in inputs {
            let message = try XCTUnwrap(ControlMessage.input(input))
            XCTAssertEqual(message.remoteInputEvent, input)
        }
    }

    func testRemoteClickKindsRoundTrip() throws {
        let inputs = [
            RemoteInputEvent.click(x: 0.2, y: 0.3),
            RemoteInputEvent.doubleClick(x: 0.4, y: 0.5),
            RemoteInputEvent.click(secondary: true, x: 0.6, y: 0.7)
        ]

        for input in inputs {
            let message = try XCTUnwrap(ControlMessage.input(input))
            XCTAssertEqual(message.remoteInputEvent, input)
        }
    }

    func testLocalNetworkPermissionStatesAreNotOptimistic() {
        XCTAssertFalse(LocalNetworkAccessState.checking.isGranted)
        XCTAssertFalse(LocalNetworkAccessState.unavailable("Wi-Fi is off").isGranted)
        XCTAssertTrue(LocalNetworkAccessState.denied.needsPermission)
        XCTAssertTrue(LocalNetworkAccessState.granted.isGranted)
    }

    func testLANFramingHandlesPartialPacket() throws {
        let payload = Data([0xA1, 1, 2, 3, 4])
        let framed = LANWire.framed(payload)
        var buffer = Data(framed.prefix(3))
        XCTAssertTrue(try LANWire.takeFrames(from: &buffer).isEmpty)
        buffer.append(framed.dropFirst(3))
        XCTAssertEqual(try LANWire.takeFrames(from: &buffer), [payload])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLANFramingHandlesMultiplePacketsInOneRead() throws {
        let first = Data([0xA1, 1, 2, 3])
        let second = Data([0xA3, 4, 5, 6, 7])
        var buffer = LANWire.framed(first)
        buffer.append(LANWire.framed(second))

        XCTAssertEqual(try LANWire.takeFrames(from: &buffer), [first, second])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLANFramingPreservesIncompleteTailAfterCompletePacket() throws {
        let first = Data([0xA1, 1])
        let second = LANWire.framed(Data([0xA3, 2, 3, 4]))
        var buffer = LANWire.framed(first)
        buffer.append(second.prefix(5))

        XCTAssertEqual(try LANWire.takeFrames(from: &buffer), [first])
        XCTAssertEqual(buffer, second.prefix(5))
    }

    func testLANKeyAgreementAndEncryption() throws {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let clientPublic = client.publicKey.rawRepresentation
        let serverPublic = server.publicKey.rawRepresentation
        let clientKey = try LANWire.sessionKey(
            privateKey: client,
            peerPublicKey: serverPublic,
            clientPublicKey: clientPublic,
            serverPublicKey: serverPublic
        )
        let serverKey = try LANWire.sessionKey(
            privateKey: server,
            peerPublicKey: clientPublic,
            clientPublicKey: clientPublic,
            serverPublicKey: serverPublic
        )
        let packet = try PacketCodec.encode(.control(ControlMessage(.startFallback)))
        var buffer = try LANWire.encrypted(packet, key: clientKey)
        let encryptedPayload = try XCTUnwrap(LANWire.takeFrames(from: &buffer).first)
        XCTAssertEqual(try LANWire.decrypt(encryptedPayload, key: serverKey), packet)
    }
}
