import XCTest
import Security

private final class MemoryPairingDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func synchronize() -> Bool { true }
}

final class PairingRevocationTests: XCTestCase {
    @MainActor private func fixture(deleteSucceeds: Bool = true) -> (MacPairingSecurity, () -> MacPairingSecurity) {
        let defaults = MemoryPairingDefaults(suiteName: "SidecarBridge.in-memory-security-tests")!
        var credentials: [String: Data] = [:]
        let make = {
            MacPairingSecurity(defaults: defaults, read: { credentials[$0] },
                write: { credentials[$1] = $0; return true },
                delete: { prefix in
                    if deleteSucceeds { credentials = credentials.filter { !$0.key.hasPrefix(prefix) } }
                    return deleteSucceeds
                }, authorize: { _ in }, automaticallyRotate: false)
        }
        return (make(), make)
    }
    private let identity = BridgePeerIdentity(deviceID: "test-ipad", deviceName: "Test iPad", deviceKind: "iPad")
    private let nonce = Data(repeating: 1, count: 32)
    private let binding = Data("test binding".utf8)

    @MainActor private func verify(_ security: MacPairingSecurity, secret: Data) -> PairingVerification {
        let proof = PairingProof.make(secret: secret, role: .client, identity: identity,
            macID: security.macID, nonce: nonce, channelBinding: binding)
        return security.verify(identity: identity, nonce: nonce, proof: proof, channelBinding: binding)
    }

    func testBadProofDoesNotDisableSavedCredential() async throws {
        try await MainActor.run {
            let (security, _) = fixture()
            let credential = try XCTUnwrap(verify(security, secret: Data(security.pairingCode.utf8)).issuedCredential)
            XCTAssertFalse(verify(security, secret: Data(repeating: 0, count: 32)).accepted)
            XCTAssertFalse(security.requiresPairingCode(for: identity))
            XCTAssertTrue(verify(security, secret: credential).accepted)
        }
    }

    func testGlobalGuessLimitDoesNotLockOutValidCredential() async throws {
        try await MainActor.run {
            let (security, _) = fixture()
            let credential = try XCTUnwrap(verify(security, secret: Data(security.pairingCode.utf8)).issuedCredential)
            for i in 0..<30 {
                let stranger = BridgePeerIdentity(deviceID: "stranger-\(i)", deviceName: "Unknown", deviceKind: "iPad")
                XCTAssertFalse(security.verify(identity: stranger, nonce: nonce,
                    proof: Data(repeating: 0, count: 32), channelBinding: binding).accepted)
            }
            XCTAssertTrue(verify(security, secret: credential).accepted)
            XCTAssertFalse(verify(security, secret: Data(security.pairingCode.utf8)).accepted, "Code guesses remain throttled")
        }
    }

    func testFailedDeletionCannotRestoreOldCredentialAfterRelaunch() async throws {
        try await MainActor.run {
            let (security, relaunch) = fixture(deleteSucceeds: false)
            let credential = try XCTUnwrap(verify(security, secret: Data(security.pairingCode.utf8)).issuedCredential)
            XCTAssertFalse(security.forgetAllDevices())
            XCTAssertFalse(verify(security, secret: credential).accepted)
            let next = relaunch()
            XCTAssertTrue(next.requiresPairingCode(for: identity))
            XCTAssertFalse(verify(next, secret: credential).accepted)
            XCTAssertTrue(verify(next, secret: Data(next.pairingCode.utf8)).accepted)
        }
    }

    func testRevocationDropsQueuedWorkAndAllowsNewGeneration() {
        let gate = AuthorizationGeneration()
        let old = gate.token
        gate.invalidate()
        var executed = false
        XCTAssertFalse(gate.perform(ifCurrent: old) { executed = true })
        XCTAssertFalse(executed)
        XCTAssertTrue(gate.perform(ifCurrent: gate.token) { executed = true })
        XCTAssertTrue(executed)
    }

    func testDeletionErrorsAreNotSuccess() {
        XCTAssertTrue(SecureCredentialStore.deletionSucceeded(errSecSuccess))
        XCTAssertTrue(SecureCredentialStore.deletionSucceeded(errSecItemNotFound))
        XCTAssertFalse(SecureCredentialStore.deletionSucceeded(errSecInteractionNotAllowed))
        XCTAssertFalse(SecureCredentialStore.deletionSucceeded(errSecAuthFailed))
    }

    func testMainHopDoesNotHoldAuthorizationLockWhileWaiting() async {
        let gate = AuthorizationGeneration()
        let token = gate.token
        let completed = expectation(description: "background main hop completes")
        await MainActor.run {
            DispatchQueue.global().async {
                let result = gate.onMain(ifCurrent: token) { Thread.isMainThread }
                XCTAssertEqual(result, true)
                completed.fulfill()
            }
            // A queued main callback must be able to use the same gate even
            // while input is waiting for its main-thread operation.
            XCTAssertTrue(gate.perform(ifCurrent: token) {})
        }
        await fulfillment(of: [completed], timeout: 3)
    }

    func testMainHopRevalidatesAfterRevocation() async {
        let gate = AuthorizationGeneration()
        let old = gate.token
        await MainActor.run { gate.invalidate() }
        let completed = expectation(description: "stale main work rejected")
        DispatchQueue.global().async {
            let result: Bool? = gate.onMain(ifCurrent: old) { XCTFail("Revoked work executed"); return true }
            XCTAssertNil(result)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
    }

    func testPreAuthenticationFrameCapRejectsHeaderBeforeBodyArrives() {
        var buffer = Data([0, 0, 32, 0]) // 8192-byte declared body, not sent.
        XCTAssertThrowsError(try LANWire.takeFrames(from: &buffer, maximumSize: 4096))
    }
}
