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

    func testRelativePointerRoundTripAndCoalescing() throws {
        let first = RemoteInputEvent.pointerDelta(x: 0.02, y: -0.01)
        let second = RemoteInputEvent.pointerDelta(x: 0.03, y: 0.04)
        let message = try XCTUnwrap(ControlMessage.input(first))
        XCTAssertEqual(message.remoteInputEvent, first)

        var coalescer = RemoteInputCoalescer()
        coalescer.enqueue(first)
        coalescer.enqueue(second)
        let accumulated = try XCTUnwrap(coalescer.popFirst())
        XCTAssertEqual(accumulated.kind, .pointerDelta)
        XCTAssertEqual(accumulated.deltaX ?? 0, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(accumulated.deltaY ?? 0, 0.03, accuracy: 0.000_001)
    }

    func testCurrentPointerClickDoesNotCarryAbsoluteCoordinates() {
        let input = RemoteInputEvent.primaryDownAtCurrentPointer(clickCount: 2)
        XCTAssertEqual(input.kind, .primaryDown)
        XCTAssertNil(input.x)
        XCTAssertNil(input.y)
        XCTAssertEqual(input.clickCount, 2)
    }

    func testDeviceIdentityAndLANHandshakeRoundTrip() throws {
        let identity = BridgePeerIdentity(
            deviceID: "stable-device-id",
            deviceName: "Euler’s iPhone",
            deviceKind: "iPhone"
        )
        XCTAssertEqual(identity.stableKey, "stable-device-id")

        let handshake = LANHandshake(
            deviceName: identity.deviceName,
            publicKey: Data([1, 2, 3]),
            deviceID: identity.deviceID,
            deviceKind: identity.deviceKind
        )
        let framed = try LANWire.handshake(handshake, marker: LANWire.clientHello)
        var buffer = framed
        let payload = try XCTUnwrap(LANWire.takeFrames(from: &buffer).first)
        let decoded = try LANWire.decodeHandshake(payload, marker: LANWire.clientHello)
        XCTAssertEqual(decoded.deviceID, identity.deviceID)
        XCTAssertEqual(decoded.deviceKind, "iPhone")
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

    func testControlArrowShortcutsCarryControlModifier() {
        for key in ["up", "down", "left", "right"] {
            let event = RemoteKeyboardInput.event(key: key, modifiers: ["control"])
            XCTAssertEqual(event?.kind, .key)
            XCTAssertEqual(event?.key, key)
            XCTAssertEqual(event?.modifiers, ["control"])
        }
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
            RemoteInputEvent.click(secondary: true, x: 0.6, y: 0.7),
            RemoteInputEvent.doubleClick(secondary: true, x: 0.8, y: 0.9)
        ]

        for input in inputs {
            let message = try XCTUnwrap(ControlMessage.input(input))
            XCTAssertEqual(message.remoteInputEvent, input)
        }
    }

    func testRemotePointerButtonCalibrationAndSwap() {
        XCTAssertEqual(
            RemotePointerButtonMapping.calibrated(reportedLeftButton: .primary),
            .system
        )
        XCTAssertEqual(
            RemotePointerButtonMapping.calibrated(reportedLeftButton: .secondary),
            .swapped
        )
        XCTAssertEqual(
            RemotePointerButtonMapping.swapped.resolvedButton(for: .primary),
            .secondary
        )
        XCTAssertEqual(
            RemotePointerButtonMapping.swapped.resolvedButton(for: .secondary),
            .primary
        )
    }

    func testRemoteReleaseButtonsRoundTrip() throws {
        let input = RemoteInputEvent.releaseButtons()
        let message = try XCTUnwrap(ControlMessage.input(input))
        XCTAssertEqual(message.remoteInputEvent, input)
    }

    func testPressAndHoldPreservesClickCount() throws {
        let inputs = [
            RemoteInputEvent.primaryDown(x: 0.2, y: 0.3, clickCount: 2),
            RemoteInputEvent.primaryDrag(x: 0.4, y: 0.5, clickCount: 2),
            RemoteInputEvent.primaryUp(x: 0.6, y: 0.7, clickCount: 2)
        ]

        for input in inputs {
            let message = try XCTUnwrap(ControlMessage.input(input))
            XCTAssertEqual(message.remoteInputEvent, input)
            XCTAssertEqual(message.remoteInputEvent?.clickCount, 2)
        }
    }

    func testContinuousInputAcknowledgementIsSampled() {
        var pointer = RemoteInputEvent.pointer(x: 0.2, y: 0.3)
        pointer.sequence = 11
        XCTAssertFalse(pointer.shouldAcknowledge)
        pointer.sequence = 12
        XCTAssertTrue(pointer.shouldAcknowledge)

        var down = RemoteInputEvent.primaryDown(x: 0.2, y: 0.3)
        down.sequence = 13
        XCTAssertTrue(down.shouldAcknowledge)
    }

    func testTrackpadScrollMetadataRoundTrip() throws {
        var input = RemoteInputEvent.scroll(
            x: 2.5,
            y: -4.25,
            phase: .changed,
            continuous: true
        )
        input.sequence = 25

        let message = try XCTUnwrap(ControlMessage.input(input))
        XCTAssertEqual(message.remoteInputEvent, input)
        XCTAssertEqual(message.remoteInputEvent?.scrollPhase, .changed)
        XCTAssertEqual(message.remoteInputEvent?.isContinuousScroll, true)
    }

    func testScrollPhaseBarriersAreAlwaysAcknowledged() {
        var began = RemoteInputEvent.scroll(
            x: 0,
            y: 0,
            phase: .began,
            continuous: true
        )
        began.sequence = 13
        XCTAssertTrue(began.shouldAcknowledge)

        var changed = RemoteInputEvent.scroll(
            x: 1,
            y: 2,
            phase: .changed,
            continuous: true
        )
        changed.sequence = 13
        XCTAssertFalse(changed.shouldAcknowledge)
        changed.sequence = 24
        XCTAssertTrue(changed.shouldAcknowledge)

        var ended = RemoteInputEvent.scroll(
            x: 0,
            y: 0,
            phase: .ended,
            continuous: true
        )
        ended.sequence = 25
        XCTAssertTrue(ended.shouldAcknowledge)
    }

    func testContinuousInputCoalescerKeepsLatestPointerAndDrag() {
        var coalescer = RemoteInputCoalescer()
        var firstPointer = RemoteInputEvent.pointer(x: 0.1, y: 0.2)
        firstPointer.sequence = 1
        var latestPointer = RemoteInputEvent.pointer(x: 0.3, y: 0.4)
        latestPointer.sequence = 2
        coalescer.enqueue(firstPointer)
        coalescer.enqueue(latestPointer)

        XCTAssertEqual(coalescer.count, 1)
        XCTAssertEqual(coalescer.popFirst(), latestPointer)

        let down = RemoteInputEvent.primaryDown(x: 0.3, y: 0.4)
        var firstDrag = RemoteInputEvent.primaryDrag(x: 0.5, y: 0.6)
        firstDrag.sequence = 3
        var latestDrag = RemoteInputEvent.primaryDrag(x: 0.7, y: 0.8)
        latestDrag.sequence = 4
        let up = RemoteInputEvent.primaryUp(x: 0.7, y: 0.8)
        coalescer.enqueue(down)
        coalescer.enqueue(firstDrag)
        coalescer.enqueue(latestDrag)
        coalescer.enqueue(up)

        XCTAssertEqual(coalescer.pending, [down, latestDrag, up])
    }

    func testContinuousInputCoalescerAccumulatesScrollBetweenPhaseBarriers() {
        var coalescer = RemoteInputCoalescer()
        let began = RemoteInputEvent.scroll(
            x: 0,
            y: 0,
            phase: .began,
            continuous: true
        )
        var first = RemoteInputEvent.scroll(
            x: 1.25,
            y: -2,
            phase: .changed,
            continuous: true
        )
        first.sequence = 10
        var second = RemoteInputEvent.scroll(
            x: 0.75,
            y: -3,
            phase: .changed,
            continuous: true
        )
        second.sequence = 11
        let ended = RemoteInputEvent.scroll(
            x: 0,
            y: 0,
            phase: .ended,
            continuous: true
        )

        coalescer.enqueue(began)
        coalescer.enqueue(first)
        coalescer.enqueue(second)
        coalescer.enqueue(ended)

        XCTAssertEqual(coalescer.count, 3)
        XCTAssertEqual(coalescer.popFirst(), began)
        let accumulated = coalescer.popFirst()
        XCTAssertEqual(accumulated?.deltaX, 2)
        XCTAssertEqual(accumulated?.deltaY, -5)
        XCTAssertEqual(accumulated?.sequence, 11)
        XCTAssertEqual(coalescer.popFirst(), ended)
    }

    func testClickSequenceRecognizesOnlyNearbyShortDoubleClick() {
        var tracker = RemoteClickSequenceTracker()
        XCTAssertEqual(
            tracker.nextCount(x: 100, y: 100, at: 1, interval: 0.42, maximumDistance: 44),
            1
        )
        tracker.complete(
            count: 1,
            x: 100,
            y: 100,
            beganAt: 1,
            endedAt: 1.08,
            interval: 0.42,
            movedBeyondClickSlop: false
        )

        XCTAssertEqual(
            tracker.nextCount(x: 110, y: 108, at: 1.25, interval: 0.42, maximumDistance: 44),
            2
        )
        XCTAssertEqual(
            tracker.nextCount(x: 200, y: 200, at: 1.25, interval: 0.42, maximumDistance: 44),
            1
        )
    }

    func testLongHoldDoesNotSeedDoubleClickSequence() {
        var tracker = RemoteClickSequenceTracker()
        tracker.complete(
            count: 1,
            x: 100,
            y: 100,
            beganAt: 1,
            endedAt: 1.75,
            interval: 0.42,
            movedBeyondClickSlop: false
        )

        XCTAssertEqual(
            tracker.nextCount(x: 100, y: 100, at: 1.8, interval: 0.42, maximumDistance: 44),
            1
        )
    }

    func testDragDoesNotSeedDoubleClickSequence() {
        var tracker = RemoteClickSequenceTracker()
        tracker.complete(
            count: 1,
            x: 100,
            y: 100,
            beganAt: 1,
            endedAt: 1.08,
            interval: 0.42,
            movedBeyondClickSlop: true
        )

        XCTAssertEqual(
            tracker.nextCount(x: 100, y: 100, at: 1.2, interval: 0.42, maximumDistance: 44),
            1
        )
    }

    func testDirectTouchPointerAndTapBarriersStayOrdered() {
        var coalescer = RemoteInputCoalescer()
        let stalePointer = RemoteInputEvent.pointer(x: 0.1, y: 0.2)
        let latestPointer = RemoteInputEvent.pointer(x: 0.4, y: 0.5)
        let down = RemoteInputEvent.primaryDown(x: 0.4, y: 0.5, clickCount: 2)
        let up = RemoteInputEvent.primaryUp(x: 0.4, y: 0.5, clickCount: 2)

        coalescer.enqueue(stalePointer)
        coalescer.enqueue(latestPointer)
        coalescer.enqueue(down)
        coalescer.enqueue(up)

        XCTAssertEqual(coalescer.pending, [latestPointer, down, up])
        XCTAssertFalse(down.isCoalescibleInput)
        XCTAssertFalse(up.isCoalescibleInput)
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
