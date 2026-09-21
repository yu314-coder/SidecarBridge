import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCodeView: View {
    let payload: String
    var size: CGFloat = 224

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let qrImage = PairingQRCodeRenderer.image(payload: payload) {
                    Image(decorative: qrImage, scale: 1).interpolation(.none).resizable().scaledToFit()
                } else {
                    Text("QR unavailable\nUse the code instead").multilineTextAlignment(.center).foregroundStyle(.black)
                }
            }
            .frame(width: size, height: size)
            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            Text("Scan to fill · tap to connect").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

enum PairingQRCodeRenderer {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 2
        return cache
    }()

    static func image(payload: String) -> CGImage? {
        if let cached = cache.object(forKey: payload as NSString) { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Explicit quiet zone and integer module scaling keep the symbol
        // readable on Retina displays and in a larger pairing window.
        let bounds = output.extent.insetBy(dx: -4, dy: -4)
        let padded = output.composited(over: CIImage(color: .white).cropped(to: bounds))
            .cropped(to: bounds).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(padded, from: padded.extent) else { return nil }
        // Memory-only, bounded cache: telemetry redraws never re-encode the QR.
        cache.setObject(image, forKey: payload as NSString)
        return image
    }
}
