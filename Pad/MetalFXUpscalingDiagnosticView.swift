import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif
import SwiftUI
import UIKit

struct MetalFXUpscalingDiagnosticView: View {
    @StateObject private var diagnostic = MetalFXUpscalingDiagnosticModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Local MetalFX test", systemImage: "wand.and.rays")
                    .font(.title2.bold())
                Text("Creates a synthetic 1920 × 1080 desktop frame and asks Apple’s MetalFX spatial scaler to produce 2560 × 1440. It does not connect to a Mac, use the network, or read your photos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticRow("Device", diagnostic.deviceName)
                        diagnosticRow("MetalFX", diagnostic.supportSummary)
                        diagnosticRow("Resolution", "1920 × 1080 → 2560 × 1440")
                        diagnosticRow("Measured time", diagnostic.timingSummary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Capability", systemImage: "gauge.with.dots.needle.50percent")
                }

                if diagnostic.isRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Running six GPU passes…")
                    }
                } else {
                    Button {
                        diagnostic.run()
                    } label: {
                        Label(diagnostic.hasRun ? "Run again" : "Run upscaling test", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(!diagnostic.canRun)
                }

                if let source = diagnostic.sourceImage {
                    comparisonCard(title: "1080p input", image: source)
                }
                if let output = diagnostic.outputImage {
                    comparisonCard(title: "MetalFX 2K output", image: output)
                }

                if let error = diagnostic.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Text("This measures the scaler itself, not network or H.264 performance. A successful result proves the device can run the 1080p-to-2K stage; live-stream integration still needs separate decoder/render-path testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Upscaling diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .task { diagnostic.prepare() }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.callout)
    }

    private func comparisonCard(title: String, image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
private final class MetalFXUpscalingDiagnosticModel: ObservableObject {
    @Published private(set) var deviceName = "Checking…"
    @Published private(set) var supportSummary = "Checking…"
    @Published private(set) var timingSummary = "Not run"
    @Published private(set) var sourceImage: UIImage?
    @Published private(set) var outputImage: UIImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var hasRun = false
    @Published private(set) var canRun = false

    func prepare() {
        #if targetEnvironment(simulator)
        deviceName = MTLCreateSystemDefaultDevice()?.name ?? "Simulator GPU"
        supportSummary = "Physical device required"
        canRun = false
        #else
        guard let device = MTLCreateSystemDefaultDevice() else {
            deviceName = "No Metal device"
            supportSummary = "Unavailable"
            canRun = false
            return
        }
        deviceName = device.name
        canRun = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        supportSummary = canRun ? "Spatial scaler supported" : "Not supported on this device"
        #endif
    }

    func run() {
        guard canRun, !isRunning else { return }
        isRunning = true
        errorMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MetalFXUpscalingDiagnosticEngine.run()
            }.value
            sourceImage = result.sourceImage
            outputImage = result.outputImage
            timingSummary = result.timingSummary
            errorMessage = result.errorMessage
            hasRun = true
            isRunning = false
        }
    }
}

private struct MetalFXUpscalingDiagnosticResult: @unchecked Sendable {
    let sourceImage: UIImage?
    let outputImage: UIImage?
    let timingSummary: String
    let errorMessage: String?
}

private enum MetalFXUpscalingDiagnosticEngine {
    static func run() -> MetalFXUpscalingDiagnosticResult {
        #if targetEnvironment(simulator)
        return .init(sourceImage: nil, outputImage: nil, timingSummary: "Unavailable", errorMessage: "MetalFX must be measured on a physical iPhone or iPad.")
        #else
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else {
            return .init(sourceImage: nil, outputImage: nil, timingSummary: "Unavailable", errorMessage: "MetalFX spatial scaling is not supported on this device.")
        }

        let inputWidth = Int(DisplayUpscalingPolicy.diagnosticInput.width)
        let inputHeight = Int(DisplayUpscalingPolicy.diagnosticInput.height)
        let outputWidth = Int(DisplayUpscalingPolicy.diagnosticOutput.width)
        let outputHeight = Int(DisplayUpscalingPolicy.diagnosticOutput.height)

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inputWidth
        descriptor.inputHeight = inputHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            return .init(sourceImage: nil, outputImage: nil, timingSummary: "Unavailable", errorMessage: "The device reported support but could not create a MetalFX scaler.")
        }

        let inputBytes = makeTestPattern(width: inputWidth, height: inputHeight)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: inputWidth, height: inputHeight, mipmapped: false
        )
        inputDescriptor.storageMode = .shared
        inputDescriptor.usage = scaler.colorTextureUsage.union(.shaderRead)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false
        )
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let inputTexture = device.makeTexture(descriptor: inputDescriptor),
              let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            return .init(sourceImage: nil, outputImage: nil, timingSummary: "Failed", errorMessage: "Could not allocate diagnostic textures.")
        }
        inputBytes.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            inputTexture.replace(
                region: MTLRegionMake2D(0, 0, inputWidth, inputHeight),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: inputWidth * 4
            )
        }

        scaler.colorTexture = inputTexture
        scaler.inputContentWidth = inputWidth
        scaler.inputContentHeight = inputHeight
        scaler.outputTexture = outputTexture

        var measurements: [Double] = []
        for pass in 0..<6 {
            guard let commandBuffer = queue.makeCommandBuffer() else { break }
            let started = ProcessInfo.processInfo.systemUptime
            scaler.encode(commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                return .init(sourceImage: image(bytes: inputBytes, width: inputWidth, height: inputHeight), outputImage: nil, timingSummary: "Failed", errorMessage: commandBuffer.error?.localizedDescription ?? "MetalFX command failed.")
            }
            if pass > 0 {
                measurements.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            }
        }

        let rowBytes = outputWidth * 4
        let byteCount = rowBytes * outputHeight
        guard let readback = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return .init(sourceImage: image(bytes: inputBytes, width: inputWidth, height: inputHeight), outputImage: nil, timingSummary: "Failed", errorMessage: "Could not allocate the output readback buffer.")
        }
        blit.copy(
            from: outputTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            return .init(sourceImage: image(bytes: inputBytes, width: inputWidth, height: inputHeight), outputImage: nil, timingSummary: "Failed", errorMessage: commandBuffer.error?.localizedDescription ?? "Output readback failed.")
        }

        let outputBytes = Data(bytes: readback.contents(), count: byteCount)
        guard !measurements.isEmpty else {
            return .init(sourceImage: image(bytes: inputBytes, width: inputWidth, height: inputHeight), outputImage: nil, timingSummary: "Failed", errorMessage: "The device did not create a complete timing sample.")
        }
        let median = measurements.sorted()[measurements.count / 2]
        let budget = median <= 8.3 ? "within a 120 FPS frame budget" : (median <= 16.7 ? "within a 60 FPS frame budget" : "slower than a 60 FPS frame budget")
        return .init(
            sourceImage: image(bytes: inputBytes, width: inputWidth, height: inputHeight),
            outputImage: image(bytes: outputBytes, width: outputWidth, height: outputHeight),
            timingSummary: String(format: "%.2f ms median • %@", median, budget),
            errorMessage: nil
        )
        #endif
    }

    private static func makeTestPattern(width: Int, height: Int) -> Data {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let pixels = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let panel = ((x / 240) + (y / 135)).isMultiple(of: 2)
                    let fineLine = x.isMultiple(of: 32) || y.isMultiple(of: 32)
                    pixels[index] = fineLine ? 220 : (panel ? 42 : 28)
                    pixels[index + 1] = fineLine ? 170 : (panel ? 48 : 32)
                    pixels[index + 2] = fineLine ? 70 : (panel ? 55 : 38)
                    pixels[index + 3] = 255
                }
            }
            // Fine one-pixel desktop-style rules expose blur, ringing and broken edges.
            for y in stride(from: 90, to: height - 90, by: 90) {
                for x in 80..<(width - 80) {
                    let index = (y * width + x) * 4
                    pixels[index] = 245; pixels[index + 1] = 245; pixels[index + 2] = 245
                }
            }
        }
        return bytes
    }

    private static func image(bytes: Data, width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
