import AVFoundation
import CoreImage
import Metal
import MetalKit
import UIKit

#if !targetEnvironment(simulator)
import MetalFX
#endif

@MainActor
final class MetalFXLiveUpscaler: NSObject {
    var onStatusChanged: ((String) -> Void)?

    private weak var hostView: UIView?
    private weak var sourceLayer: AVSampleBufferDisplayLayer?
    private let metalView: MTKView
    private var displayLink: CADisplayLink?
    private var enabled = false
    private var sourceSize = CGSize.zero
    private var lastReportedStatus = "Off"

    #if !targetEnvironment(simulator)
    private let renderer: MetalFXFrameRenderer?
    #endif

    init(hostView: UIView, sourceLayer: AVSampleBufferDisplayLayer) {
        self.hostView = hostView
        self.sourceLayer = sourceLayer
        let device = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: .zero, device: device)
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.autoResizeDrawable = true
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isHidden = true
        #if !targetEnvironment(simulator)
        if let device, MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            renderer = MetalFXFrameRenderer(device: device, metalView: metalView)
        } else {
            renderer = nil
        }
        #endif
        super.init()
        hostView.addSubview(metalView)
        #if !targetEnvironment(simulator)
        renderer?.onFrameCompleted = { [weak self] detail in
            guard let self, self.enabled else { return }
            self.metalView.isHidden = false
            self.publish(detail)
        }
        renderer?.onFailure = { [weak self] detail in
            guard let self else { return }
            self.metalView.isHidden = true
            self.publish("Fallback renderer • \(detail)")
        }
        #endif
    }

    deinit {
        displayLink?.invalidate()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            #if targetEnvironment(simulator)
            metalView.isHidden = true
            publish("Physical device required")
            #else
            guard #available(iOS 17.4, *) else {
                metalView.isHidden = true
                publish("Requires iOS 17.4 or later")
                return
            }
            guard renderer != nil else {
                metalView.isHidden = true
                publish("Unavailable on this device")
                return
            }
            startDisplayLink()
            publish("Ready • waiting for a 1080p frame")
            #endif
        } else {
            stopDisplayLink()
            metalView.isHidden = true
            publish("Off")
        }
    }

    func layout(in bounds: CGRect) {
        guard metalView.superview != nil else { return }
        layoutMetalView(in: bounds)
    }

    func reset() {
        metalView.isHidden = true
        #if !targetEnvironment(simulator)
        renderer?.reset()
        #endif
        if enabled { publish("Ready • waiting for a 1080p frame") }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        let maximum = Float(max(hostView?.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond, 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick() {
        guard enabled,
              UIApplication.shared.applicationState == .active,
              let sourceLayer,
              sourceLayer.status != .failed else { return }
        #if !targetEnvironment(simulator)
        guard #available(iOS 17.4, *) else { return }
        guard let pixelBuffer = sourceLayer.sampleBufferRenderer.displayedPixelBuffer() else { return }
        let newSourceSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        if newSourceSize != sourceSize {
            sourceSize = newSourceSize
            if let hostView { layoutMetalView(in: hostView.bounds) }
        }
        guard let renderer else { return }
        // AVSampleBufferVideoRenderer is allowed to reuse the same
        // CVPixelBuffer object for successive displayed frames. Pointer
        // identity therefore is not a frame identifier. De-duplicating here
        // froze the MetalFX overlay on an old frame even though the decoder,
        // remote input, and underlying display layer were still live. Let the
        // renderer's one-command-buffer in-flight gate provide back-pressure
        // and always offer it the latest displayed image.
        _ = renderer.render(pixelBuffer)
        #endif
    }

    private func layoutMetalView(in bounds: CGRect) {
        let frame: CGRect
        if sourceSize.width > 0, sourceSize.height > 0 {
            frame = AVMakeRect(aspectRatio: sourceSize, insideRect: bounds).integral
        } else {
            frame = bounds
        }
        guard metalView.frame != frame else { return }
        metalView.frame = frame
        let scale = hostView?.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalView.drawableSize = CGSize(
            width: max(2, (frame.width * scale).rounded()),
            height: max(2, (frame.height * scale).rounded())
        )
    }

    private func publish(_ status: String) {
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        onStatusChanged?(status)
    }
}

#if !targetEnvironment(simulator)
@MainActor
private final class MetalFXFrameRenderer {
    var onFrameCompleted: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let device: MTLDevice
    private weak var metalView: MTKView?
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var scaler: (any MTLFXSpatialScaler)?
    private var inputTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var configuredInput = CGSize.zero
    private var configuredOutput = CGSize.zero
    private var inFlight = false
    private var lastStatusAt: TimeInterval = 0
    private var consecutiveFailures = 0
    private var currentStatus = ""

    init?(device: MTLDevice, metalView: MTKView) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.metalView = metalView
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    func reset() {
        scaler = nil
        inputTexture = nil
        outputTexture = nil
        configuredInput = .zero
        configuredOutput = .zero
        inFlight = false
        consecutiveFailures = 0
        currentStatus = ""
    }

    func render(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard !inFlight, let metalView else { return false }
        let inputSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let outputSize = CGSize(
            width: max(2, Int(metalView.drawableSize.width) & ~1),
            height: max(2, Int(metalView.drawableSize.height) & ~1)
        )
        guard DisplayUpscalingPolicy.shouldUpscale(
            enabled: true,
            supported: true,
            input: inputSize,
            output: outputSize
        ) else {
            onFailure?("native stream already matches the display")
            return false
        }
        guard configureIfNeeded(input: inputSize, output: outputSize),
              let scaler, let inputTexture, let outputTexture,
              let drawable = metalView.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            fail("could not configure MetalFX")
            return false
        }

        let started = ProcessInfo.processInfo.systemUptime
        inFlight = true
        let inputBounds = CGRect(origin: .zero, size: inputSize)
        ciContext.render(
            CIImage(cvPixelBuffer: pixelBuffer),
            to: inputTexture,
            commandBuffer: commandBuffer,
            bounds: inputBounds,
            colorSpace: colorSpace
        )
        scaler.colorTexture = inputTexture
        scaler.inputContentWidth = Int(inputSize.width)
        scaler.inputContentHeight = Int(inputSize.height)
        scaler.outputTexture = outputTexture
        scaler.encode(commandBuffer: commandBuffer)
        guard let scaledImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
            inFlight = false
            fail("could not create the scaled image")
            return false
        }
        ciContext.render(
            scaledImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] completed in
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                if completed.status == .completed {
                    self.consecutiveFailures = 0
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastStatusAt >= 1 {
                        self.lastStatusAt = now
                        self.currentStatus = String(
                            format: "Active • %d × %d → %d × %d • %.1f ms",
                            Int(inputSize.width), Int(inputSize.height),
                            Int(outputSize.width), Int(outputSize.height), elapsed
                        )
                    } else if self.currentStatus.isEmpty {
                        self.currentStatus = self.lastSuccessfulStatus(input: inputSize, output: outputSize)
                    }
                    self.onFrameCompleted?(self.currentStatus)
                } else {
                    self.fail(completed.error?.localizedDescription ?? "GPU command failed")
                }
            }
        }
        commandBuffer.commit()
        return true
    }

    private func configureIfNeeded(input: CGSize, output: CGSize) -> Bool {
        guard scaler == nil || input != configuredInput || output != configuredOutput else { return true }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = Int(input.width)
        descriptor.inputHeight = Int(input.height)
        descriptor.outputWidth = Int(output.width)
        descriptor.outputHeight = Int(output.height)
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else { return false }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(input.width),
            height: Int(input.height),
            mipmapped: false
        )
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = scaler.colorTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(output.width),
            height: Int(output.height),
            mipmapped: false
        )
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union([.shaderRead, .shaderWrite, .renderTarget])
        guard let inputTexture = device.makeTexture(descriptor: inputDescriptor),
              let outputTexture = device.makeTexture(descriptor: outputDescriptor) else { return false }
        self.scaler = scaler
        self.inputTexture = inputTexture
        self.outputTexture = outputTexture
        configuredInput = input
        configuredOutput = output
        return true
    }

    private func lastSuccessfulStatus(input: CGSize, output: CGSize) -> String {
        "Active • \(Int(input.width)) × \(Int(input.height)) → \(Int(output.width)) × \(Int(output.height))"
    }

    private func fail(_ detail: String) {
        consecutiveFailures += 1
        inFlight = false
        if consecutiveFailures <= 3 || consecutiveFailures.isMultiple(of: 60) {
            onFailure?(detail)
        }
    }
}
#endif
