import XCTest

final class NativeSidecarSetupTests: XCTestCase {
    func testRequestRoundTripsBothInstructionRoutes() {
        for route in NativeSidecarRoute.allCases {
            let request = NativeSidecarSetupRequest(route: route)
            XCTAssertEqual(NativeSidecarSetupRequest.parse(request.wireValue), request)
        }
    }

    func testMalformedRequestsCannotSelectUnrecognisedRoutes() {
        let id = UUID().uuidString
        for value in ["sidecar-setup:bad:usb", "sidecar-setup:\(id):automatic",
                      "sidecar-setup:\(id):usb:extra", "sidecar-setup:\(id):",
                      "https://example.com", String(repeating: "x", count: 81)] {
            XCTAssertNil(NativeSidecarSetupRequest.parse(value))
        }
    }

    func testOpeningSettingsRequiresAnExplicitRequestAndIsNotNativeSuccess() {
        var progress = NativeSidecarSetupProgress()
        XCTAssertFalse(progress.receive("sidecar-settings-opened"))
        XCTAssertEqual(progress.phase, .ready)
        let request = progress.begin(route: .usb)
        XCTAssertTrue(progress.isRequesting)
        XCTAssertTrue(progress.receive(request.successReply))
        XCTAssertEqual(progress.phase, .chooseOnMac)
        XCTAssertNil(progress.request)
        XCTAssertTrue(progress.detail.contains("not yet a Sidecar connection"))
    }

    func testWrongRequestAndLateRepliesAreIgnored() {
        var progress = NativeSidecarSetupProgress()
        let old = progress.begin(route: .nearby)
        let current = progress.begin(route: .usb)
        XCTAssertFalse(progress.receive(old.successReply))
        XCTAssertTrue(progress.isRequesting)
        XCTAssertTrue(progress.receive(current.failureReply))
        XCTAssertEqual(progress.phase, .openManually)
        XCTAssertFalse(progress.receive(current.successReply))
    }

    func testTimeoutBelongsToCurrentAttemptOnly() {
        var progress = NativeSidecarSetupProgress()
        let old = progress.begin(route: .nearby)
        let current = progress.begin(route: .usb)
        progress.expire(id: old.id)
        XCTAssertTrue(progress.isRequesting)
        progress.expire(id: current.id)
        XCTAssertEqual(progress.phase, .noReply)
        XCTAssertFalse(progress.receive(current.successReply))
    }

    func testDisconnectResetRejectsOldAcknowledgements() {
        var progress = NativeSidecarSetupProgress()
        let request = progress.begin(route: .usb)
        progress.reset()
        XCTAssertFalse(progress.receive(request.successReply))
        XCTAssertFalse(progress.receive("sidecar-settings-opened"))
        progress.expire(id: request.id)
        XCTAssertEqual(progress.phase, .ready)
    }

    func testOlderMacBuildAcknowledgementEndsWait() {
        var progress = NativeSidecarSetupProgress()
        progress.begin(route: .nearby)
        XCTAssertTrue(progress.receive("sidecar-settings-opened"))
        XCTAssertFalse(progress.isRequesting)
        XCTAssertEqual(progress.phase, .chooseOnMac)
    }

    func testLegacyNativeMessagesCannotClaimAConnectedSession() {
        var progress = NativeSidecarSetupProgress()
        progress.begin(route: .nearby)
        for value in ["sidecar-wired", "sidecar-wireless", "sidecar-connected", "sidecar-failed"] {
            XCTAssertTrue(NativeSidecarSetupProgress.isSetupStatus(value))
            XCTAssertFalse(progress.receive(value))
        }
        XCTAssertTrue(progress.isRequesting)
        XCTAssertFalse(NativeSidecarSetupProgress.isSetupStatus("fallback-active"))
    }

    func testSettingsPaneAcceptedDoesNotOpenAnotherApp() async {
        await MainActor.run {
            var opened: [URL] = []
            let connector = SidecarConnector(openURL: { opened.append($0); return true }, settingsApplicationURL: {
                XCTFail("No fallback needed")
                return nil
            })
            XCTAssertTrue(connector.openSettings())
            XCTAssertEqual(opened.count, 1)
            XCTAssertEqual(opened.first?.scheme, "x-apple.systempreferences")
        }
    }

    func testMissingPaneHandlerFallsBackToSettingsApplication() async {
        await MainActor.run {
            let application = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            var opened: [URL] = []
            let connector = SidecarConnector(openURL: {
                opened.append($0)
                return $0 == application
            }, settingsApplicationURL: { application })
            XCTAssertTrue(connector.openSettings())
            XCTAssertEqual(opened.count, 2)
            XCTAssertEqual(opened.last, application)
        }
    }

    func testOpenFailureIsReportedInsteadOfFakeSuccess() async {
        await MainActor.run {
            let missing = SidecarConnector(openURL: { _ in false }, settingsApplicationURL: { nil })
            XCTAssertFalse(missing.openSettings())
            let blocked = SidecarConnector(openURL: { _ in false }, settingsApplicationURL: {
                URL(fileURLWithPath: "/System/Applications/System Settings.app")
            })
            XCTAssertFalse(blocked.openSettings())
        }
    }
}
