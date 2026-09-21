import XCTest
import Network

final class RFBProtocolTests: XCTestCase {
    func testAuthenticationMatchesIndependentDESVector() throws {
        // OpenSSL DES-ECB, reversed-bit ASCII key for "password", no padding.
        let response = try RFBProtocol.challengeResponse(Data(0..<16), password: "password")
        XCTAssertEqual(response.map { String(format: "%02x", $0) }.joined(), "b866924125c8eebb9debc1db61c538e2")
        for password in ["", "123456789", "密碼"] {
            XCTAssertThrowsError(try RFBProtocol.challengeResponse(Data(count: 16), password: password))
        }
        XCTAssertThrowsError(try RFBProtocol.challengeResponse(Data(count: 15), password: "test"))
    }

    func testWireFormatAndInputChords() {
        XCTAssertEqual(RFBProtocol.pixelFormat.count, 20)
        XCTAssertEqual(RFBProtocol.encodings.count, 16)
        XCTAssertEqual(RFBProtocol.updateRequest(width: 1920, height: 1080, incremental: true),
                       Data([3, 1, 0, 0, 0, 0, 7, 128, 4, 56]))
        var input = RFBInput()
        for (name, symbol): (String, UInt32) in [("up", 0xff52), ("down", 0xff54), ("left", 0xff51), ("right", 0xff53)] {
            XCTAssertEqual(input.encode(.key(name, modifiers: ["control"]), width: 100, height: 100),
                RFBProtocol.key(0xffe3, down: true) + RFBProtocol.key(symbol, down: true)
                + RFBProtocol.key(symbol, down: false) + RFBProtocol.key(0xffe3, down: false))
        }
        XCTAssertEqual(input.encode(.key("v", modifiers: ["command"]), width: 100, height: 100),
            RFBProtocol.key(0xffe7, down: true) + RFBProtocol.key(118, down: true)
            + RFBProtocol.key(118, down: false) + RFBProtocol.key(0xffe7, down: false))
        XCTAssertEqual(RFBInput.keysym(key: "中", hid: nil), 0x01004e2d)
        XCTAssertEqual(RFBInput.keysym(key: nil, hid: 4), 97)
    }

    func testPointerDragModifierClickScrollAndBounds() {
        var input = RFBInput()
        XCTAssertEqual(input.encode(.primaryDown(x: 0, y: 0, modifiers: ["shift"]), width: 101, height: 101),
                       RFBProtocol.key(0xffe1, down: true) + RFBProtocol.pointer(x: 0, y: 0, buttons: 1))
        XCTAssertEqual(input.encode(.primaryDrag(x: 1, y: 1), width: 101, height: 101),
                       RFBProtocol.pointer(x: 100, y: 100, buttons: 1))
        XCTAssertEqual(input.encode(.releaseButtons(), width: 101, height: 101),
                       RFBProtocol.pointer(x: 100, y: 100, buttons: 0) + RFBProtocol.key(0xffe1, down: false))
        XCTAssertEqual(input.encode(.doubleClick(secondary: true), width: 101, height: 101),
                       (RFBProtocol.pointer(x: 100, y: 100, buttons: 4) + RFBProtocol.pointer(x: 100, y: 100, buttons: 0))
                       + (RFBProtocol.pointer(x: 100, y: 100, buttons: 4) + RFBProtocol.pointer(x: 100, y: 100, buttons: 0)))
        XCTAssertTrue(input.encode(.scroll(x: 0, y: 6), width: 101, height: 101).isEmpty)
        XCTAssertEqual(input.encode(.scroll(x: 0, y: 6), width: 101, height: 101),
                       RFBProtocol.pointer(x: 100, y: 100, buttons: 8) + RFBProtocol.pointer(x: 100, y: 100, buttons: 0))
        XCTAssertEqual(input.encode(.pointer(x: -100, y: 100), width: 101, height: 101),
                       RFBProtocol.pointer(x: 0, y: 100, buttons: 0))
        XCTAssertEqual(input.encode(.pointer(x: .nan, y: .infinity), width: 101, height: 101),
                       RFBProtocol.pointer(x: 0, y: 100, buttons: 0))
    }

    func testFramebufferCopyOverlapAndMalformedBounds() throws {
        var frame = RFBFramebuffer()
        try frame.resize(width: 2, height: 3)
        try frame.raw(x: 0, y: 0, width: 2, height: 3, bytes: Data(0..<24))
        try frame.copy(x: 0, y: 1, width: 2, height: 2, sourceX: 0, sourceY: 0)
        XCTAssertEqual(frame.pixels, Data(0..<8) + Data(0..<16))
        XCTAssertThrowsError(try frame.raw(x: 1, y: 0, width: 2, height: 1, bytes: Data(count: 8)))
        XCTAssertThrowsError(try frame.raw(x: 0, y: 0, width: 1, height: 1, bytes: Data(count: 3)))
        XCTAssertThrowsError(try frame.resize(width: 8192, height: 8192))
        XCTAssertThrowsError(try frame.resize(width: 0, height: 1))
    }

    func testRFB38FragmentedAuthenticationFramesResizeAndInput() async throws {
        try await exerciseServer(version: "003.889") // Apple's version negotiates down to standard 3.8.
    }

    func testRFB33AuthenticationAndFrames() async throws {
        try await exerciseServer(version: "003.003")
    }

    func testRefusesUnauthenticatedServerAndWrongPassword() async throws {
        for wrongPassword in [false, true] {
            let listener = try NWListener(using: .tcp, on: .any)
            let ready = expectation(description: "rejection listener ready")
            let finished = expectation(description: "rejection server complete")
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                let peer = RFBTestPeer(connection)
                Task {
                    defer { finished.fulfill() }
                    do {
                        try await peer.send(Data("RFB 003.008\n".utf8))
                        _ = try await peer.read(12)
                        if wrongPassword {
                            try await peer.send(Data([1, 2]))
                            _ = try await peer.read(1)
                            try await peer.send(Data(0..<16))
                            _ = try await peer.read(16)
                            let reason = Data("Incorrect VNC password".utf8)
                            try await peer.send(Data([0, 0, 0, 1]) + Data(RFBProtocol.long(UInt32(reason.count))) + reason)
                        } else {
                            try await peer.send(Data([1, 1]))
                        }
                    } catch { XCTFail("Rejection server: \(error)") }
                    // The client must reject without waiting for this server to close.
                }
            }
            listener.start(queue: .global())
            await fulfillment(of: [ready], timeout: 5)
            let session = MacScreenSharingSession(host: "127.0.0.1", port: try XCTUnwrap(listener.port).rawValue)
            let watchdog = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { session.cancel() } }
            do { _ = try await session.open(password: "password"); XCTFail("Unsafe or rejected authentication must fail") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(wrongPassword ? "Incorrect VNC password" : "Enable ‘VNC viewers"))
            }
            session.cancel(); watchdog.cancel(); listener.cancel()
            await fulfillment(of: [finished], timeout: 5)
        }
    }

    private func exerciseServer(version: String) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        let finished = expectation(description: "server verified exchange")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            let peer = RFBTestPeer(connection)
            Task {
                defer { finished.fulfill() }
                do {
                    // Deliberately fragment the banner and pixel data across sends.
                    try await peer.send(Data("RFB ".utf8))
                    try await peer.send(Data("\(version)\n".utf8))
                    let banner = try await peer.read(12)
                    XCTAssertEqual(String(decoding: banner, as: UTF8.self), version == "003.003" ? "RFB 003.003\n" : "RFB 003.008\n")
                    if version == "003.003" { try await peer.send(Data([0, 0, 0, 2])) }
                    else {
                        try await peer.send(Data([2, 1, 2]))
                        let method = try await peer.read(1)
                        XCTAssertEqual(method, Data([2])) // Never select unauthenticated security type 1.
                    }
                    try await peer.send(Data(0..<16))
                    let response = try await peer.read(16)
                    XCTAssertEqual(response, try RFBProtocol.challengeResponse(Data(0..<16), password: "password"))
                    try await peer.send(Data([0, 0, 0, 0]))
                    let shared = try await peer.read(1)
                    XCTAssertEqual(shared, Data([1]))
                    let initHeader = Data([0, 2, 0, 1]) + RFBProtocol.pixelFormat.dropFirst(4)
                        + Data([0, 0, 0, 4]) + Data("Test".utf8)
                    try await peer.send(initHeader)
                    let format = try await peer.read(20), encodings = try await peer.read(16), request = try await peer.read(10)
                    XCTAssertEqual(format, RFBProtocol.pixelFormat)
                    XCTAssertEqual(encodings, RFBProtocol.encodings)
                    XCTAssertEqual(request, RFBProtocol.updateRequest(width: 2, height: 1, incremental: false))
                    try await peer.send(Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0, 255]))
                    try await peer.send(Data([0, 0, 0, 0, 255, 0, 0])) // red then green, RGBX
                    _ = try await peer.read(10)
                    // DesktopSize followed by raw pixels, exercising live resolution changes.
                    let resize = Data([0, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 1]) + Data(RFBProtocol.long(UInt32(bitPattern: -223)))
                    try await peer.send(resize + Data([0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 255, 0]))
                    let resizedRequest = try await peer.read(10)
                    XCTAssertEqual(resizedRequest, RFBProtocol.updateRequest(width: 1, height: 1, incremental: false))
                    let key = try await peer.read(8)
                    XCTAssertEqual(key, RFBProtocol.key(0xff52, down: true))
                    connection.cancel()
                } catch { XCTFail("Mock server: \(error)"); connection.cancel() }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let session = MacScreenSharingSession(host: "127.0.0.1", port: port.rawValue)
        defer { session.cancel() }
        // Guard against a protocol regression hanging the entire test runner.
        let watchdog = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); if !Task.isCancelled { session.cancel() } }
        defer { watchdog.cancel() }
        let (name, width, height) = try await session.open(password: "password")
        XCTAssertEqual(name, "Test"); XCTAssertEqual(width, 2); XCTAssertEqual(height, 1)
        let first = try await session.nextFrame()
        XCTAssertEqual(first.width, 2)
        XCTAssertEqual(first.dataProvider?.data as Data?, Data([255, 0, 0, 0, 0, 255, 0, 0]))
        let second = try await session.nextFrame()
        XCTAssertEqual(second.width, 1)
        XCTAssertEqual(second.dataProvider?.data as Data?, Data([0, 0, 255, 0]))
        session.send(RFBProtocol.key(0xff52, down: true))
        await fulfillment(of: [finished], timeout: 5)
        do { _ = try await session.nextFrame(); XCTFail("Closed server should end the frame loop") }
        catch { /* expected disconnect, not an indefinitely reused old image */ }
    }
}

private final class RFBTestPeer: @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func read(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? RFBError.invalid("Test socket closed")) }
                }
            }
            result.append(chunk)
        }
        return result
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
