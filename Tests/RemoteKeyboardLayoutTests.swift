import XCTest
import SwiftUI
import AppKit

final class RemoteKeyboardLayoutTests: XCTestCase {
    func testPanelFitsWindowSizes() async throws {
        try await MainActor.run {
            for size in [CGSize(width: 1366, height: 1024), CGSize(width: 1024, height: 1366),
                         CGSize(width: 744, height: 1133), CGSize(width: 375, height: 700),
                         CGSize(width: 812, height: 375)] {
                let panel = SoftwareKeyboardLayout.panelSize(in: size)
                XCTAssertLessThanOrEqual(panel.width + 24, size.width)
                XCTAssertLessThanOrEqual(panel.height, size.height / 2)
                for mode in SoftwareKeyboardMode.allCases {
                    let content = RemoteKeyboardToolbar(
                        mode: .constant(mode), modifiers: .constant([]), onKey: { _, _ in },
                        onShortcut: { _, _ in }, onInputMode: {}, onCycleInputMode: {},
                        onClearModifiers: {}, onHide: {}, maximumHeight: panel.height - 16)
                        .frame(width: panel.width - 20)
                        .environment(\.colorScheme, .dark)
                    let host = NSHostingView(rootView: content)
                    host.frame = CGRect(x: 0, y: 0, width: panel.width - 20, height: panel.height - 16)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = NSImage(size: host.bounds.size)
                    image.addRepresentation(bitmap)
                    XCTAssertLessThanOrEqual(image.size.width, panel.width - 20 + 1)
                    XCTAssertLessThanOrEqual(image.size.height, panel.height - 16 + 1)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Fit \(Int(size.width))x\(Int(size.height)) \(mode.rawValue)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
    func testBothPagesFitLandscapePanel() async throws {
        try await MainActor.run {
            for mode in SoftwareKeyboardMode.allCases {
                let renderer = ImageRenderer(content: RemoteKeyboardToolbar(
                    mode: .constant(mode), modifiers: .constant([]), onKey: { _, _ in },
                    onShortcut: { _, _ in }, onInputMode: {}, onCycleInputMode: {},
                    onClearModifiers: {}, onHide: {})
                    .frame(width: 980).padding(10).background(Color.black)
                    .environment(\.colorScheme, .dark))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertLessThanOrEqual(image.size.height, 540, "\(mode) must fit without cutting off bottom keys")
                let attachment = XCTAttachment(image: image)
                attachment.name = "Custom keyboard \(mode.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
