import XCTest
import CryptoKit

final class PacketCodecTests: XCTestCase {
    func testShutdownProtectionOnlyEngagesForRemoteSystemTerminationWithBlockers() {
        XCTAssertTrue(ShutdownProtectionPolicy.shouldEngage(
            isSystemTermination: true,
            isEnabled: true,
            hasRemoteSession: true,
            blockingApplicationCount: 2
        ))
        XCTAssertFalse(ShutdownProtectionPolicy.shouldEngage(
            isSystemTermination: false,
            isEnabled: true,
            hasRemoteSession: true,
            blockingApplicationCount: 2
        ))
        XCTAssertFalse(ShutdownProtectionPolicy.shouldEngage(
            isSystemTermination: true,
            isEnabled: true,
            hasRemoteSession: false,
            blockingApplicationCount: 2
        ))
        XCTAssertFalse(ShutdownProtectionPolicy.shouldEngage(
            isSystemTermination: true,
            isEnabled: true,
            hasRemoteSession: true,
            blockingApplicationCount: 0
        ))
    }

    func testShutdownProtectionWaitsUntilOtherAppsFinish() {
        XCTAssertEqual(
            ShutdownProtectionPolicy.decisionWhileEngaged(
                hasRemoteSession: true,
                blockingApplicationCount: 2,
                elapsed: 10
            ),
            .hold
        )
        XCTAssertEqual(
            ShutdownProtectionPolicy.decisionWhileEngaged(
                hasRemoteSession: true,
                blockingApplicationCount: 0,
                elapsed: 10
            ),
            .finishTermination
        )
    }

    func testShutdownProtectionCancelsUnsafeTermination() {
        XCTAssertEqual(
            ShutdownProtectionPolicy.decisionWhileEngaged(
                hasRemoteSession: false,
                blockingApplicationCount: 1,
                elapsed: 10
            ),
            .cancelTermination
        )
        XCTAssertEqual(
            ShutdownProtectionPolicy.decisionWhileEngaged(
                hasRemoteSession: true,
                blockingApplicationCount: 1,
                elapsed: ShutdownProtectionPolicy.maximumHoldDuration
            ),
            .cancelTermination
        )
    }

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

    func testClipboardControlRoundTrip() throws {
        let message = ControlMessage.clipboardText("Hello from the iPad 👋")
        XCTAssertEqual(
            try PacketCodec.decode(PacketCodec.encode(.control(message))),
            .control(message)
        )
        XCTAssertEqual(message.clipboardTextPayload, "Hello from the iPad 👋")
    }

    func testClipboardTextIsCappedBeforeTransport() {
        let original = String(repeating: "界", count: 30_000)
        let prepared = ClipboardTransfer.prepare(original)
        XCTAssertLessThanOrEqual(prepared.utf8.count, ClipboardTransfer.maximumTextBytes)
        XCTAssertTrue(original.hasPrefix(prepared))
        XCTAssertNotEqual(prepared, original)
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
            message: nil,
            sha256: Data(repeating: 7, count: SHA256.Digest.byteCount)
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
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: receiverDirectory.path)
                .contains(where: { $0.hasSuffix(".partial") })
        )
    }

    @MainActor
    func testFileTransferRejectsWrongDigestAndDeletesPartialFile() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTransfers/\(UUID().uuidString)", isDirectory: true)
        let senderDirectory = root.appendingPathComponent("sender", isDirectory: true)
        let receiverDirectory = root.appendingPathComponent("receiver", isDirectory: true)
        try FileManager.default.createDirectory(at: senderDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = senderDirectory.appendingPathComponent("tampered.bin")
        try Data(repeating: 0x5A, count: FileTransferEngine.chunkSize + 1).write(to: source)
        let sender = FileTransferEngine { senderDirectory }
        let receiver = FileTransferEngine { receiverDirectory }
        sender.sendPacket = { packet in
            var delivered = packet
            if packet.kind == .complete, packet.message == nil {
                delivered.sha256 = Data(repeating: 0, count: SHA256.Digest.byteCount)
            }
            receiver.handle(delivered)
        }
        receiver.sendPacket = { sender.handle($0) }

        var receivedURL: URL?
        var receivedError: String?
        receiver.onReceived = { receivedURL = $0 }
        receiver.onError = { receivedError = $0 }
        sender.sendFile(at: source)

        XCTAssertNil(receivedURL)
        XCTAssertNotNil(receivedError)
        XCTAssertFalse(receiver.isBusy)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: receiverDirectory.path).isEmpty)
                ?? true
        )
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

    func testShortcutEventsPreserveKeyAndModifierOrder() {
        let input = RemoteInputEvent.key(
            "left",
            modifiers: ["shift", "option", "control"]
        )
        XCTAssertEqual(input.kind, .key)
        XCTAssertEqual(input.key, "left")
        XCTAssertEqual(input.modifiers, ["option", "control", "shift"])
    }

    func testModifierClickHasNoAbsolutePointerCoordinates() {
        let input = RemoteInputEvent.click(modifiers: ["shift", "option"])
        XCTAssertEqual(input.kind, .primaryClick)
        XCTAssertNil(input.x)
        XCTAssertNil(input.y)
        XCTAssertEqual(input.modifiers, ["option", "shift"])
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

    func testRemoteDisplayGeometryUsesSameLetterboxForInputAndOverlay() throws {
        let size = CGSize(width: 1_024, height: 768)
        let content = RemoteDisplayGeometry.contentRect(
            in: size,
            aspectRatio: 16.0 / 9.0
        )
        XCTAssertEqual(content.width, 1_024, accuracy: 0.001)
        XCTAssertEqual(content.height, 576, accuracy: 0.001)
        XCTAssertEqual(content.minY, 96, accuracy: 0.001)

        let normalized = try XCTUnwrap(
            RemoteDisplayGeometry.normalizedPoint(
                CGPoint(x: 512, y: 384),
                in: size,
                aspectRatio: 16.0 / 9.0
            )
        )
        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.000_001)
    }

    func testRemoteDisplayGeometryKeepsZoomedInputAlignedWithRenderedContent() throws {
        let size = CGSize(width: 1_024, height: 768)
        let zoomed = RemoteDisplayGeometry.transformedContentRect(
            in: size,
            aspectRatio: 16.0 / 9.0,
            zoomScale: 2,
            zoomOffset: CGSize(width: 38, height: -24)
        )
        let normalized = try XCTUnwrap(
            RemoteDisplayGeometry.normalizedPoint(
                CGPoint(x: zoomed.midX, y: zoomed.midY),
                in: size,
                aspectRatio: 16.0 / 9.0,
                zoomScale: 2,
                zoomOffset: CGSize(width: 38, height: -24)
            )
        )
        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.000_001)
        XCTAssertNil(
            RemoteDisplayGeometry.normalizedPoint(
                CGPoint(x: zoomed.minX - 1, y: zoomed.midY),
                in: size,
                aspectRatio: 16.0 / 9.0,
                zoomScale: 2,
                zoomOffset: CGSize(width: 38, height: -24)
            )
        )
    }

    func testRelativePointerDeltaMatchesDisplayGeometryWithoutSensitivityDrift() throws {
        let delta = try XCTUnwrap(
            RemoteDisplayGeometry.normalizedDelta(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 125, y: 120),
                in: CGSize(width: 1_024, height: 768),
                aspectRatio: 16.0 / 9.0
            )
        )
        let bounds = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        // The letterboxed 16:9 content is 1,024 × 576 inside the 4:3 view,
        // so 25 × 20 view points becomes this exact display-space delta.
        XCTAssertEqual(delta.x * (bounds.width - 1), 25.0 / 1_024.0 * 1_919.0, accuracy: 0.001)
        XCTAssertEqual(delta.y * (bounds.height - 1), 20.0 / 576.0 * 1_079.0, accuracy: 0.001)
    }

    func testDisplayPointClampsToTheActualDisplayPixelBounds() {
        let bounds = CGRect(x: -1_920, y: 20, width: 1_920, height: 1_080)
        XCTAssertEqual(
            RemoteDisplayGeometry.displayPoint(
                for: CGPoint(x: 1, y: 1),
                in: bounds
            ),
            CGPoint(x: -1, y: 1_099)
        )
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
            protocolVersion: LANWire.securityProtocolVersion,
            deviceName: identity.deviceName,
            publicKey: Data(repeating: 3, count: 32),
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

    func testAdvertisedHostMetadataOnlyAcceptsPrivateIPv4Addresses() {
        XCTAssertEqual(
            BridgeNetworkMetadata.decodePrivateIPv4Addresses(
                "192.168.1.124,10.0.0.8,172.20.10.2,8.8.8.8,not-an-ip,192.168.1.124"
            ),
            ["10.0.0.8", "172.20.10.2", "192.168.1.124"]
        )
    }

    func testPairingProofBindsDeviceMacAndNonce() {
        let identity = BridgePeerIdentity(
            deviceID: "trusted-phone",
            deviceName: "Euler’s iPhone",
            deviceKind: "iPhone"
        )
        let secret = Data("ABCD2345EFGH6789".utf8)
        let nonce = Data(repeating: 7, count: 32)
        let clientPublicKey = Data(repeating: 3, count: 32)
        let serverPublicKey = Data(repeating: 4, count: 32)
        let channelBinding = PairingProof.lanChannelBinding(
            clientPublicKey: clientPublicKey,
            serverPublicKey: serverPublicKey
        )
        let proof = PairingProof.make(
            secret: secret,
            role: .client,
            identity: identity,
            macID: "trusted-mac",
            nonce: nonce,
            channelBinding: channelBinding
        )
        XCTAssertTrue(PairingProof.verify(
            proof,
            secret: secret,
            role: .client,
            identity: identity,
            macID: "trusted-mac",
            nonce: nonce,
            channelBinding: channelBinding
        ))
        XCTAssertFalse(PairingProof.verify(
            proof,
            secret: Data("ZZZZ2345EFGH6789".utf8),
            role: .client,
            identity: identity,
            macID: "trusted-mac",
            nonce: nonce,
            channelBinding: channelBinding
        ))
        XCTAssertFalse(PairingProof.verify(
            proof,
            secret: secret,
            role: .client,
            identity: identity,
            macID: "different-mac",
            nonce: nonce,
            channelBinding: channelBinding
        ))
        XCTAssertFalse(PairingProof.verify(
            proof,
            secret: secret,
            role: .client,
            identity: identity,
            macID: "trusted-mac",
            nonce: nonce,
            channelBinding: PairingProof.lanChannelBinding(
                clientPublicKey: clientPublicKey,
                serverPublicKey: Data(repeating: 5, count: 32)
            )
        ))
        XCTAssertFalse(PairingProof.verify(
            proof,
            secret: secret,
            role: .server,
            identity: identity,
            macID: "trusted-mac",
            nonce: nonce,
            channelBinding: channelBinding
        ))
    }

    func testServerAcceptanceRequiresIndependentRoleSeparatedProof() {
        let identity = BridgePeerIdentity(
            deviceID: "trusted-pad",
            deviceName: "iPad",
            deviceKind: "iPad"
        )
        let secret = Data("ABCD2345EFGH6789".utf8)
        let nonce = Data(repeating: 1, count: 32)
        let binding = Data("p2p-session".utf8)
        let clientProof = PairingProof.make(
            secret: secret,
            role: .client,
            identity: identity,
            macID: "mac",
            nonce: nonce,
            channelBinding: binding
        )
        let serverProof = PairingProof.make(
            secret: secret,
            role: .server,
            identity: identity,
            macID: "mac",
            nonce: nonce,
            channelBinding: binding
        )

        XCTAssertNotEqual(clientProof, serverProof)
        XCTAssertTrue(PairingProof.verify(
            serverProof,
            secret: secret,
            role: .server,
            identity: identity,
            macID: "mac",
            nonce: nonce,
            channelBinding: binding
        ))
        XCTAssertFalse(PairingProof.verify(
            clientProof,
            secret: secret,
            role: .server,
            identity: identity,
            macID: "mac",
            nonce: nonce,
            channelBinding: binding
        ))
    }

    func testPairingCodeIsSixteenDigitsAndNormalizesGroupedInput() {
        let code = PairingCode.generate()
        XCTAssertEqual(code.count, PairingCode.characterCount)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })
        XCTAssertEqual(PairingCode.normalize(PairingCode.formatted(code)), code)
        XCTAssertEqual(PairingCode.normalize("1234-5678-9012-3456"), "1234567890123456")
        XCTAssertEqual(PairingCode.formattedInput("123456789012345678"), "1234-5678-9012-3456")
        XCTAssertEqual(PairingCode.normalize("ABCD-1234"), "1234")
    }

    func testLegacyHandshakeFailsClosed() throws {
        let legacy = LANHandshake(
            deviceName: "Old Mac",
            publicKey: Data(repeating: 2, count: 32)
        )
        var buffer = try LANWire.handshake(legacy, marker: LANWire.serverHello)
        let payload = try XCTUnwrap(LANWire.takeFrames(from: &buffer).first)

        XCTAssertThrowsError(try LANWire.decodeHandshake(payload, marker: LANWire.serverHello)) {
            XCTAssertEqual(
                ($0 as? LANWire.LANError)?.localizedDescription,
                LANWire.LANError.unsupportedSecurityProtocol.localizedDescription
            )
        }
    }

    func testMultipeerInvitationRequiresCurrentSecurityProtocol() throws {
        let invitation = MultipeerInvitationContext(
            protocolVersion: LANWire.securityProtocolVersion,
            identity: BridgePeerIdentity(
                deviceID: "trusted-pad",
                deviceName: "iPad",
                deviceKind: "iPad"
            ),
            clientPublicKey: Data(repeating: 3, count: 32)
        )
        let encoded = try JSONEncoder().encode(invitation)
        XCTAssertEqual(try JSONDecoder().decode(MultipeerInvitationContext.self, from: encoded), invitation)
    }

    func testPairingPacketRoundTrip() throws {
        let message = PairingMessage(
            kind: .accepted,
            protocolVersion: LANWire.securityProtocolVersion,
            proof: Data(repeating: 7, count: 32),
            credential: Data(repeating: 9, count: 32),
            detail: nil
        )
        let encoded = try PacketCodec.encode(.authentication(message))
        XCTAssertEqual(try PacketCodec.decode(encoded), .authentication(message))
    }

    func testAcceptedAuthenticationWithoutServerProofIsRejected() throws {
        let message = PairingMessage(
            kind: .accepted,
            protocolVersion: LANWire.securityProtocolVersion
        )
        var encoded = Data([5])
        encoded.append(try JSONEncoder().encode(message))

        XCTAssertThrowsError(try PacketCodec.decode(encoded)) {
            XCTAssertEqual($0 as? PacketCodec.PacketError, .invalidAuthenticationMessage)
        }
    }

    func testOversizedControlMessageIsRejected() throws {
        let message = ControlMessage(.status, detail: String(repeating: "x", count: 64 * 1024 + 1))
        let encoded = try PacketCodec.encode(.control(message))

        XCTAssertThrowsError(try PacketCodec.decode(encoded)) {
            XCTAssertEqual($0 as? PacketCodec.PacketError, .invalidControlMessage)
        }
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

    func testRemoteKeyboardChineseTextRoundTripsWithoutUnicodeLoss() throws {
        let text = "中文输入法测试：你好，世界！"
        let input = try XCTUnwrap(RemoteKeyboardInput.event(text: text))
        let message = try XCTUnwrap(ControlMessage.input(input))

        XCTAssertEqual(message.remoteInputEvent?.kind, .text)
        XCTAssertEqual(message.remoteInputEvent?.text, text)
        XCTAssertNil(message.remoteInputEvent?.modifiers)
    }

    func testRemoteKeyboardInputModeRoundTripsAsBCP47Language() throws {
        let input = RemoteInputEvent.inputMode(language: " zh_Hans ")
        let message = try XCTUnwrap(ControlMessage.input(input))

        XCTAssertEqual(message.remoteInputEvent?.kind, .inputMode)
        XCTAssertEqual(message.remoteInputEvent?.text, "zh-Hans")
    }

    func testRemoteKeyboardInputModeCycleRoundTrips() throws {
        let input = RemoteInputEvent.cycleInputMode()
        let message = try XCTUnwrap(ControlMessage.input(input))

        XCTAssertEqual(message.remoteInputEvent?.kind, .cycleInputMode)
        XCTAssertNil(message.remoteInputEvent?.text)
        XCTAssertNil(message.remoteInputEvent?.hidUsage)
    }

    func testAnnouncedInputLanguageIsNotOverwrittenByStaleResponder() {
        var state = RemoteInputLanguageState()
        XCTAssertEqual(
            state.resolve(
                announcedLanguage: "zh_Hant",
                responderLanguage: "en-US"
            ),
            "zh-Hant"
        )
        XCTAssertEqual(
            state.resolve(
                announcedLanguage: nil,
                responderLanguage: "en-US"
            ),
            "zh-Hant"
        )
        XCTAssertEqual(
            state.resolve(
                announcedLanguage: "en-US",
                responderLanguage: "zh-Hant"
            ),
            "en-US"
        )
    }

    func testInputModeSwitchWaitsForNewLanguageInsteadOfRestoringOldOne() {
        var state = RemoteInputLanguageState()
        XCTAssertEqual(
            state.resolve(
                announcedLanguage: "en-US",
                responderLanguage: nil
            ),
            "en-US"
        )

        state.beginInputModeSwitch()
        XCTAssertNil(
            state.resolve(
                announcedLanguage: nil,
                responderLanguage: "en-US"
            )
        )
        XCTAssertEqual(
            state.resolve(
                announcedLanguage: nil,
                responderLanguage: "zh-Hant"
            ),
            "zh-Hant"
        )
    }

    func testPhysicalKeyboardUsesHIDPositionForMacInputMethods() throws {
        let input = try XCTUnwrap(RemoteKeyboardInput.event(
            hidUsage: 4,
            modifiers: ["shift"]
        ))
        let message = try XCTUnwrap(ControlMessage.input(input))

        XCTAssertEqual(message.remoteInputEvent?.kind, .key)
        XCTAssertEqual(message.remoteInputEvent?.hidUsage, 4)
        XCTAssertNil(message.remoteInputEvent?.key)
        XCTAssertEqual(message.remoteInputEvent?.modifiers, ["shift"])
    }

    func testLanguageSwitchHIDUsagesAreRecognizedWithoutBecomingTextKeys() {
        XCTAssertTrue(RemoteKeyboardInput.isLanguageSwitchHIDUsage(57))
        XCTAssertTrue(RemoteKeyboardInput.isChineseEnglishToggleHIDUsage(57))
        XCTAssertFalse(RemoteKeyboardInput.isDedicatedLanguageSwitchHIDUsage(57))
        XCTAssertTrue(RemoteKeyboardInput.isLanguageSwitchHIDUsage(144))
        XCTAssertTrue(RemoteKeyboardInput.isDedicatedLanguageSwitchHIDUsage(144))
        XCTAssertFalse(RemoteKeyboardInput.isChineseEnglishToggleHIDUsage(144))
        XCTAssertTrue(RemoteKeyboardInput.isLanguageSwitchHIDUsage(152))
        XCTAssertFalse(RemoteKeyboardInput.isLanguageSwitchHIDUsage(56))
        XCTAssertFalse(RemoteKeyboardInput.isLanguageSwitchHIDUsage(143))
        XCTAssertFalse(RemoteKeyboardInput.isLanguageSwitchHIDUsage(153))
        XCTAssertFalse(RemoteKeyboardInput.supportsRemoteHIDUsage(0))
        XCTAssertNil(RemoteKeyboardInput.event(hidUsage: 0))
    }

    func testChineseEnglishInputModeToggleRoundTrips() throws {
        let input = RemoteInputEvent.toggleChineseEnglishInputMode()
        let message = try XCTUnwrap(ControlMessage.input(input))

        XCTAssertEqual(
            message.remoteInputEvent?.kind,
            .toggleChineseEnglishInputMode
        )
    }

    func testControlSpaceIsTheExplicitInputModeSwitchShortcut() {
        XCTAssertTrue(
            RemoteKeyboardInput.isInputModeSwitchShortcut(
                hidUsage: 44,
                modifiers: ["control"]
            )
        )
        XCTAssertTrue(
            RemoteKeyboardInput.isInputModeSwitchShortcut(
                hidUsage: 44,
                modifiers: ["CONTROL"]
            )
        )
        XCTAssertFalse(
            RemoteKeyboardInput.isInputModeSwitchShortcut(
                hidUsage: 44,
                modifiers: []
            )
        )
        XCTAssertFalse(
            RemoteKeyboardInput.isInputModeSwitchShortcut(
                hidUsage: 44,
                modifiers: ["control", "shift"]
            )
        )
        XCTAssertFalse(
            RemoteKeyboardInput.isInputModeSwitchShortcut(
                hidUsage: 43,
                modifiers: ["control"]
            )
        )
    }

    func testBackgroundedViewerDoesNotTriggerHeartbeatReconnect() {
        XCTAssertFalse(
            RemoteSessionLifecyclePolicy.shouldRecoverStaleConnection(
                isViewerBackgrounded: true,
                peerSupportsHeartbeat: true,
                secondsSinceActivity: 120
            )
        )
        XCTAssertFalse(
            RemoteSessionLifecyclePolicy.shouldRecoverStaleConnection(
                isViewerBackgrounded: false,
                peerSupportsHeartbeat: false,
                secondsSinceActivity: 120
            )
        )
        XCTAssertTrue(
            RemoteSessionLifecyclePolicy.shouldRecoverStaleConnection(
                isViewerBackgrounded: false,
                peerSupportsHeartbeat: true,
                secondsSinceActivity: 10
            )
        )
    }

    func testActiveStreamIsRetainedForViewerResume() {
        XCTAssertTrue(
            RemoteSessionLifecyclePolicy.shouldRetainStreamAfterDisconnect(
                isStreaming: true
            )
        )
        XCTAssertFalse(
            RemoteSessionLifecyclePolicy.shouldRetainStreamAfterDisconnect(
                isStreaming: false
            )
        )
        XCTAssertEqual(
            RemoteSessionLifecyclePolicy.streamResumeRetentionInterval,
            300
        )
    }

    func testInputSourceCycleUsesOrderedSourcesAndWraps() {
        let sources = ["ABC", "Zhuyin", "Pinyin"]
        XCTAssertEqual(
            RemoteKeyboardInput.nextInputSourceID(
                currentID: "ABC",
                orderedIDs: sources
            ),
            "Zhuyin"
        )
        XCTAssertEqual(
            RemoteKeyboardInput.nextInputSourceID(
                currentID: "Pinyin",
                orderedIDs: sources
            ),
            "ABC"
        )
        XCTAssertEqual(
            RemoteKeyboardInput.nextInputSourceID(
                currentID: "Missing",
                orderedIDs: sources
            ),
            "ABC"
        )
        XCTAssertNil(
            RemoteKeyboardInput.nextInputSourceID(
                currentID: "ABC",
                orderedIDs: []
            )
        )
    }

    func testPhysicalHIDPositionsMapToMacVirtualKeys() {
        XCTAssertEqual(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: 4), 0)
        XCTAssertEqual(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: 30), 18)
        XCTAssertEqual(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: 44), 49)
        XCTAssertEqual(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: 79), 124)
        XCTAssertNil(RemoteKeyboardInput.macVirtualKeyCode(forHIDUsage: 0))
    }

    func testRemoteTextDeltaWaitsForCommittedChineseReplacement() {
        let anchor = String(repeating: "1", count: 64)
        let delta = RemoteTextDelta.between(anchor, and: anchor + "中文")

        XCTAssertEqual(delta.deleteCount, 0)
        XCTAssertEqual(delta.insertedText, "中文")
    }

    func testRemoteTextDeltaHandlesBackspaceByCharacter() {
        let anchor = String(repeating: "1", count: 64)
        let delta = RemoteTextDelta.between(anchor + "你好", and: anchor + "你")

        XCTAssertEqual(delta.deleteCount, 1)
        XCTAssertEqual(delta.insertedText, "")
    }

    func testRemoteTextDeltaDoesNotSplitEmojiGrapheme() {
        let anchor = String(repeating: "1", count: 64)
        let delta = RemoteTextDelta.between(anchor + "👨‍👩‍👧‍👦", and: anchor)

        XCTAssertEqual(delta.deleteCount, 1)
        XCTAssertEqual(delta.insertedText, "")
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

    func testModifiedHIDArrowsBecomeSemanticShortcutEvents() {
        let expected: [(Int, String)] = [
            (79, "right"),
            (80, "left"),
            (81, "down"),
            (82, "up")
        ]

        for (usage, key) in expected {
            let event = RemoteKeyboardInput.event(
                hidUsage: usage,
                modifiers: ["control"]
            )
            XCTAssertEqual(event?.kind, .key)
            XCTAssertEqual(event?.key, key)
            XCTAssertNil(event?.hidUsage)
            XCTAssertEqual(event?.modifiers, ["control"])
        }
    }

    func testUnmodifiedHIDArrowsStayPhysicalEvents() {
        let event = RemoteKeyboardInput.event(hidUsage: 82)
        XCTAssertEqual(event?.kind, .key)
        XCTAssertNil(event?.key)
        XCTAssertEqual(event?.hidUsage, 82)
        XCTAssertEqual(event?.modifiers, [])
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
        let clientSession = try LANWire.secureSession(
            privateKey: client,
            peerPublicKey: serverPublic,
            clientPublicKey: clientPublic,
            serverPublicKey: serverPublic,
            role: .client
        )
        let serverSession = try LANWire.secureSession(
            privateKey: server,
            peerPublicKey: clientPublic,
            clientPublicKey: clientPublic,
            serverPublicKey: serverPublic,
            role: .server
        )
        let packet = try PacketCodec.encode(.control(ControlMessage(.startFallback)))
        var buffer = try LANWire.encrypted(packet, session: clientSession)
        let encryptedPayload = try XCTUnwrap(LANWire.takeFrames(from: &buffer).first)
        XCTAssertEqual(try LANWire.decrypt(encryptedPayload, session: serverSession), packet)

        let response = try PacketCodec.encode(.control(ControlMessage(.stopFallback)))
        var responseBuffer = try LANWire.encrypted(response, session: serverSession)
        let responsePayload = try XCTUnwrap(LANWire.takeFrames(from: &responseBuffer).first)
        XCTAssertEqual(try LANWire.decrypt(responsePayload, session: clientSession), response)
    }

    func testSecurePacketRejectsReplayAndTampering() throws {
        let sessions = try makeSecureSessionPair(context: "replay-test")
        let encrypted = try sessions.client.seal(Data("click".utf8))
        XCTAssertEqual(try sessions.server.open(encrypted), Data("click".utf8))
        XCTAssertThrowsError(try sessions.server.open(encrypted)) {
            XCTAssertEqual(
                $0 as? SecurePacketSession.SecurePacketError,
                .replayedPacket
            )
        }

        let secondPair = try makeSecureSessionPair(context: "tamper-test")
        var tampered = try secondPair.client.seal(Data("keyboard".utf8))
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try secondPair.server.open(tampered))
    }

    func testSecurePacketAllowsLimitedOutOfOrderDeliveryButRejectsDuplicates() throws {
        let sessions = try makeSecureSessionPair(context: "window-test")
        let zero = try sessions.client.seal(Data([0]))
        let one = try sessions.client.seal(Data([1]))
        let two = try sessions.client.seal(Data([2]))

        XCTAssertEqual(try sessions.server.open(two), Data([2]))
        XCTAssertEqual(try sessions.server.open(zero), Data([0]))
        XCTAssertEqual(try sessions.server.open(one), Data([1]))
        XCTAssertThrowsError(try sessions.server.open(zero))
    }

    func testSecurePacketUsesDirectionalKeys() throws {
        let first = try makeSecureSessionPair(context: "direction-test")
        let second = try makeSecureSessionPair(
            context: "direction-test",
            client: first.clientPrivateKey,
            server: first.serverPrivateKey
        )
        let clientPacket = try first.client.seal(Data("client".utf8))
        XCTAssertThrowsError(try second.client.open(clientPacket))
    }

    func testSecurePacketVideoThroughput() throws {
        let payload = Data(repeating: 0xA5, count: 512 * 1024)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(options: options) {
            let sessions = try! makeSecureSessionPair(context: "throughput-test")
            for _ in 0..<16 {
                let encrypted = try! sessions.client.seal(payload)
                XCTAssertEqual(try! sessions.server.open(encrypted).count, payload.count)
            }
        }
    }

    func testSystemInformationControlRoundTrip() throws {
        let information = makeSystemInformation()
        let message = try XCTUnwrap(ControlMessage.systemInformation(information))
        let packet = try PacketCodec.decode(PacketCodec.encode(.control(message)))
        guard case .control(let decoded) = packet else {
            return XCTFail("Expected a control packet")
        }
        XCTAssertEqual(decoded.systemInformationPayload, information)
    }

    func testSystemInformationRejectsMalformedPeerSnapshot() throws {
        var information = makeSystemInformation()
        information = SystemInformation(
            platform: information.platform,
            operatingSystem: information.operatingSystem,
            deviceModel: information.deviceModel,
            architecture: information.architecture,
            processorCount: 0,
            physicalMemoryBytes: information.physicalMemoryBytes,
            availableStorageBytes: information.availableStorageBytes,
            totalStorageBytes: information.totalStorageBytes,
            thermalState: information.thermalState,
            lowPowerModeEnabled: information.lowPowerModeEnabled,
            appVersion: information.appVersion,
            appBuild: information.appBuild,
            systemUptimeSeconds: information.systemUptimeSeconds,
            collectedAt: information.collectedAt
        )
        let data = try JSONEncoder().encode(information)
        let message = ControlMessage(.systemInformation, detail: String(decoding: data, as: UTF8.self))
        XCTAssertNil(message.systemInformationPayload)
        XCTAssertNil(ControlMessage.systemInformation(information))
    }

    func testDiagnosticReportIsStructuredAndPrivacySafe() {
        let information = makeSystemInformation()
        let report = DiagnosticReportBuilder.make(
            local: information,
            remote: information,
            connection: [
                DiagnosticField("Status", "Connected\nhealthy"),
                DiagnosticField("Pairing code", "AAAA-BBBB-CCCC-DDDD"),
                DiagnosticField("IP address", "192.168.1.20"),
                DiagnosticField("File path", "/private/example")
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(report.contains("[This Device]"))
        XCTAssertTrue(report.contains("[Connected Device]"))
        XCTAssertTrue(report.contains("Status: Connected healthy"))
        XCTAssertTrue(report.contains("Privacy: excludes"))
        XCTAssertFalse(report.contains("AAAA-BBBB"))
        XCTAssertFalse(report.contains("192.168.1.20"))
        XCTAssertFalse(report.contains("/private/example"))
    }

    private func makeSystemInformation() -> SystemInformation {
        SystemInformation(
            platform: "iPadOS",
            operatingSystem: "Version 26.0",
            deviceModel: "iPad14,6",
            architecture: "arm64",
            processorCount: 8,
            physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            availableStorageBytes: 100 * 1_024 * 1_024,
            totalStorageBytes: 256 * 1_024 * 1_024,
            thermalState: "Nominal",
            lowPowerModeEnabled: false,
            appVersion: "1.0",
            appBuild: "31",
            systemUptimeSeconds: 3_661,
            collectedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeSecureSessionPair(
        context: String,
        client: Curve25519.KeyAgreement.PrivateKey = .init(),
        server: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws -> (
        client: SecurePacketSession,
        server: SecurePacketSession,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        serverPrivateKey: Curve25519.KeyAgreement.PrivateKey
    ) {
        let clientPublic = client.publicKey.rawRepresentation
        let serverPublic = server.publicKey.rawRepresentation
        return (
            try SecurePacketSession.keyAgreement(
                privateKey: client,
                peerPublicKey: serverPublic,
                clientPublicKey: clientPublic,
                serverPublicKey: serverPublic,
                role: .client,
                context: context
            ),
            try SecurePacketSession.keyAgreement(
                privateKey: server,
                peerPublicKey: clientPublic,
                clientPublicKey: clientPublic,
                serverPublicKey: serverPublic,
                role: .server,
                context: context
            ),
            client,
            server
        )
    }

    func testMainQueueExecutorMovesBackgroundWorkToMainThread() {
        let completed = expectation(description: "main queue operation")
        DispatchQueue.global(qos: .userInitiated).async {
            let ranOnMainThread = MainQueueExecutor.sync {
                Thread.isMainThread
            }
            XCTAssertTrue(ranOnMainThread)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }
}
