import XCTest
import CryptoKit

final class StreamSettingsMatrixTests: XCTestCase {
    func testCaptureClockPreservesHighCadenceAcrossCallbackBursts() {
        for fps in [60, 90, 120, 240] {
            var clock = StreamCaptureClock()
            for frame in 0..<600 {
                // Delivery may be bursty; only capture time should decide.
                let timestamp = 100 + Double(frame) / Double(fps)
                XCTAssertTrue(clock.accepts(timestamp: timestamp, frameRate: fps))
                XCTAssertFalse(clock.accepts(timestamp: timestamp, frameRate: fps))
            }
            XCTAssertFalse(clock.accepts(timestamp: .nan, frameRate: fps))
            XCTAssertTrue(clock.accepts(timestamp: 0, frameRate: fps))
            clock.reset()
            XCTAssertTrue(clock.accepts(timestamp: 0, frameRate: fps))
        }
    }

    func testCaptureClockLimitsFasterSource() {
        var clock = StreamCaptureClock()
        let accepted = (0..<240).filter {
            clock.accepts(timestamp: Double($0) / 240, frameRate: 120)
        }
        XCTAssertEqual(accepted.count, 120)
    }

    func testCaptureGateToleratesNominalSixtyFPSJitter() {
        let gate = StreamCadencePolicy.captureGateMinimumInterval(for: 60)
        XCTAssertEqual(gate, 0.0125, accuracy: 0.000_001)
        XCTAssertGreaterThan(1.0 / 60.0 * 0.90, gate)
        XCTAssertLessThan(1.0 / 120.0, gate)
    }
    func testFourKSixtyUsesBoundedLowFrameTimeCushion() {
        XCTAssertEqual(
            StreamEncoderCadencePolicy.maximumFrameDelayCount(
                width: 3_840, height: 2_160, frameRate: 60
            ),
            1
        )
        XCTAssertTrue(StreamEncoderCadencePolicy.prioritizeEncodingSpeed(
            width: 3_840, height: 2_160, frameRate: 60, memoryPressure: .normal
        ))
        XCTAssertEqual(StreamEncoderCadencePolicy.maximumInFlightFrames(
            width: 3_840, height: 2_160, frameRate: 60, memoryPressure: .normal
        ), 8)
        XCTAssertEqual(StreamEncoderCadencePolicy.maximumInFlightFrames(
            width: 3_840, height: 2_160, frameRate: 60, memoryPressure: .critical
        ), 3)
    }
    func testEverySelectableProfileSurvivesBothEncryptedTransports() throws {
        for context in ["SidecarBridge-LAN-v3", "SidecarBridge-Multipeer-v3"] {
            let client = Curve25519.KeyAgreement.PrivateKey()
            let server = Curve25519.KeyAgreement.PrivateKey()
            let cp = client.publicKey.rawRepresentation, sp = server.publicKey.rawRepresentation
            let sender = try SecurePacketSession.keyAgreement(privateKey: client, peerPublicKey: sp,
                clientPublicKey: cp, serverPublicKey: sp, role: .client, context: context)
            let receiver = try SecurePacketSession.keyAgreement(privateKey: server, peerPublicKey: cp,
                clientPublicKey: cp, serverPublicKey: sp, role: .server, context: context)
            for ultra in [false, true] {
                for resolution in StreamResolutionPreference.allCases {
                    for fps in StreamFrameRatePreference.allCases {
                        let selected = StreamPreferences(resolution: resolution, frameRate: fps.permitted(ultra: ultra), ultraModeEnabled: ultra)
                        let packet = try PacketCodec.encode(.control(ControlMessage(.hello, detail: selected.encodedDetail)))
                        let decoded = try PacketCodec.decode(receiver.open(sender.seal(packet)))
                        guard case .control(let command) = decoded else { return XCTFail("Lost preference command") }
                        XCTAssertEqual(StreamPreferences.parse(try XCTUnwrap(command.detail)), selected)
                    }
                }
            }
        }
    }

    func testSelectedCadenceAndUltraRespectViewerAndPressureLimits() {
        for ultra in [false, true] {
            for fps in StreamFrameRatePreference.allCases {
                let requested = fps.permitted(ultra: ultra).rawValue
                for nearby in [false, true] {
                    for viewer in [60, 120, 240] {
                        for memory in [StreamMemoryPressureLevel.normal, .warning, .critical] {
                            for background in [false, true] {
                                let rate = StreamCadencePolicy.effectiveFrameRate(requested: requested,
                                    displayRefreshRate: 240, isNearby: nearby, viewerIsBackgrounded: background,
                                    waitingForViewerResume: false, memoryPressure: memory,
                                    ultraModeEnabled: ultra, viewerRefreshRate: viewer)
                                var expected = min(requested, viewer)
                                expected = min(expected, StreamMemoryPressureLevel.frameRateCeiling(memory, ultraModeEnabled: ultra))
                                if background { expected = min(expected, StreamCadencePolicy.backgroundFrameRateCeiling) }
                                XCTAssertEqual(rate, expected, "\(fps), ultra=\(ultra), nearby=\(nearby), viewer=\(viewer), pressure=\(memory)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testQualityChoicesRemainDistinctAndRecoverFromPressure() {
        for (resolution, width) in [(StreamResolutionPreference.fullHD, 1920), (.twoK, 2560), (.fourK, 3840), (.adaptive, 3840)] {
            XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: resolution, memory: .normal), width)
            XCTAssertLessThanOrEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: resolution, memory: .critical), 1920)
            XCTAssertEqual(StreamQualityPolicy.captureWidth(preferred: 3840, resolution: resolution, memory: .normal), width)
        }
    }

    func testUltraOffClampsOnlyDeveloperRates() {
        for fps in StreamFrameRatePreference.allCases {
            XCTAssertEqual(fps.permitted(ultra: true), fps)
            XCTAssertEqual(fps.permitted(ultra: false).rawValue, min(fps.rawValue, 120))
        }
        XCTAssertEqual(StreamFrameRatePreference.fps240.title, "240 FPS")
    }
}
