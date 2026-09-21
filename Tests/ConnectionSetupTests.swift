import XCTest

final class ConnectionSetupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func invitation(hosts: [String] = ["192.168.1.122"]) -> PairingInvitation {
        PairingInvitation(macID: "mac-test-identity", name: "Euler’s Mac 工作站", code: "1234567890123456",
                          hosts: hosts, expiresAt: now.addingTimeInterval(300))
    }

    func testQRRoundTripWithUnicodeNameAndMultipleRoutes() throws {
        let original = invitation(hosts: ["192.168.1.122", "10.0.0.2", "172.16.1.2"])
        XCTAssertEqual(try PairingInvitation.decode(original.encoded, now: now), original)
    }
    func testQRMayUseNearbyWithoutIPv4() throws {
        XCTAssertEqual(try PairingInvitation.decode(invitation(hosts: []).encoded, now: now).hosts, [])
    }
    func testRejectsExpiredAndFarFutureQR() {
        XCTAssertThrowsError(try PairingInvitation.decode(invitation().encoded, now: now.addingTimeInterval(301)))
        XCTAssertThrowsError(try PairingInvitation.decode(invitation().encoded, now: now.addingTimeInterval(-61)))
    }
    func testRejectsPublicLoopbackAndMalformedQRHosts() {
        for host in ["8.8.8.8", "127.0.0.1", "localhost", "10.0.0.999", "192.168.1.2.evil", "10..0.1", "10.0.0.-1", "10.0.0.1:22"] {
            XCTAssertThrowsError(try PairingInvitation.decode(invitation(hosts: [host]).encoded, now: now), host)
        }
    }
    func testDiscoveryHintsAlsoRejectHostnameSuffixes() {
        XCTAssertEqual(BridgeNetworkMetadata.decodePrivateIPv4Addresses("10.0.0.1.evil,10.0.0.2,192.168.1.2.example,172.16.1.3"), ["10.0.0.2", "172.16.1.3"])
    }
    func testRejectsDuplicateFieldsWrongSchemeAndOversizedQR() {
        let payload = invitation().encoded
        XCTAssertThrowsError(try PairingInvitation.decode(payload + "&code=1234567890123456", now: now))
        XCTAssertThrowsError(try PairingInvitation.decode(payload.replacingOccurrences(of: "sidecarbridge:", with: "https:"), now: now))
        XCTAssertThrowsError(try PairingInvitation.decode(payload + "#spoof", now: now))
        XCTAssertThrowsError(try PairingInvitation.decode(String(repeating: "x", count: 2049), now: now))
    }
    func testExplicitCodeOverridesSavedCredentialForRepair() throws {
        let saved = Data(repeating: 7, count: 32)
        let selected = try XCTUnwrap(PairingSecretSelection.select(code: "1234567890123456", savedCredential: saved))
        XCTAssertFalse(selected.usedSaved)
        XCTAssertEqual(selected.secret, Data("1234567890123456".utf8))
        XCTAssertEqual(PairingSecretSelection.select(code: nil, savedCredential: saved)?.secret, saved)
        XCTAssertTrue(PairingSecretSelection.select(code: nil, savedCredential: saved)?.usedSaved == true)
        XCTAssertNil(PairingSecretSelection.select(code: "123", savedCredential: Data([1])))
    }
    func testSavedRoutesArePerMacAndContainNoPairingSecret() throws {
        let suite = "SidecarBridge.ConnectionSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SavedMacRouteStore.remember(macID: "a", name: "Mac A", hosts: ["192.168.1.10", "8.8.8.8"], defaults: defaults)
        SavedMacRouteStore.remember(macID: "b", name: "Mac B", hosts: ["192.168.1.20"], defaults: defaults)
        XCTAssertEqual(SavedMacRouteStore.route(named: "Mac A", defaults: defaults)?.hosts, ["192.168.1.10"])
        XCTAssertEqual(SavedMacRouteStore.route(named: "Mac B", defaults: defaults)?.macID, "b")
        SavedMacRouteStore.remember(macID: "a", name: "Renamed Mac", hosts: ["10.0.0.4"], defaults: defaults)
        XCTAssertNil(SavedMacRouteStore.route(named: "Mac A", defaults: defaults))
        let route = try XCTUnwrap(SavedMacRouteStore.route(named: "Renamed Mac", defaults: defaults))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["macID", "name", "hosts"]))
        SavedMacRouteStore.removeAll(defaults: defaults)
        XCTAssertNil(SavedMacRouteStore.route(named: "Mac B", defaults: defaults))
    }
    func testStandbyLANFailureDoesNotResetActiveNearbyVideo() {
        XCTAssertFalse(ConnectionRoutePolicy.shouldApplyLANEvent(wasLANConnected: false, connected: false, nearbyConnected: true))
        XCTAssertTrue(ConnectionRoutePolicy.shouldApplyLANEvent(wasLANConnected: true, connected: false, nearbyConnected: false))
        XCTAssertTrue(ConnectionRoutePolicy.shouldApplyLANEvent(wasLANConnected: false, connected: true, nearbyConnected: true))
        XCTAssertTrue(ConnectionRoutePolicy.shouldApplyLANEvent(wasLANConnected: false, connected: false, nearbyConnected: false))
    }
    func testNewAttemptInvalidatesQueuedCallbacksFromCancelledAttempt() {
        let gate = ConnectionAttemptToken()
        let first = gate.begin()
        XCTAssertTrue(gate.isCurrent(first))
        let second = gate.begin()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
        gate.begin()
        XCTAssertFalse(gate.isCurrent(second))
    }
}
