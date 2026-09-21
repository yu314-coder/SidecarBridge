import XCTest
import SwiftUI
import Vision

final class MacPairingUITests: XCTestCase {
    private func invitation() -> PairingInvitation {
        PairingInvitation(macID: "preview-not-an-authorized-device", name: "Your Mac mini",
                          code: "1234567890123456", hosts: ["192.168.1.122"], expiresAt: Date().addingTimeInterval(240))
    }

    func testRenderedQRDecodesToTheExactInvitation() throws {
        let value = invitation()
        let image = try XCTUnwrap(PairingQRCodeRenderer.image(payload: value.encoded))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payload = try XCTUnwrap(request.results?.first?.payloadStringValue)
        XCTAssertEqual(payload, value.encoded)
        XCTAssertEqual(try PairingInvitation.decode(payload).code, value.code)
    }

    func testChineseMacNameFitsTheQRProtocol() throws {
        let name = PairingInvitation.displayName(String(repeating: "我的電腦💻", count: 40) + "\n")
        XCTAssertLessThanOrEqual(name.utf8.count, 128)
        XCTAssertFalse(name.contains("\n"))
        let value = PairingInvitation(macID: "mac", name: name, code: "1234567890123456", hosts: [], expiresAt: Date().addingTimeInterval(240))
        XCTAssertEqual(try PairingInvitation.decode(value.encoded).name, name)
        XCTAssertEqual(PairingInvitation.displayName("\n  \t"), "Mac")
    }

    func testQRCacheKeepsTelemetryRedrawsCheap() throws {
        let value = invitation().encoded
        let first = try XCTUnwrap(PairingQRCodeRenderer.image(payload: value))
        XCTAssertTrue(first === PairingQRCodeRenderer.image(payload: value))
    }

    func testPairingCardPreviews() async throws {
        try await MainActor.run {
            for width in [704.0, 900.0] {
                let renderer = ImageRenderer(content:
                    MacPairingCard(invitation: invitation(), copyCode: {}, enlarge: {})
                        .frame(width: width).padding(24)
                        .background(Color(red: 0.025, green: 0.04, blue: 0.14))
                        .environment(\.colorScheme, .dark))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: cgImage).perform([textRequest])
                let text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                for group in ["1234", "5678", "9012", "3456"] {
                    XCTAssertTrue(text.contains(group), "Missing code group at \(width) pt: \(group)")
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Pairing card \(Int(width)) pt — sample code only"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
