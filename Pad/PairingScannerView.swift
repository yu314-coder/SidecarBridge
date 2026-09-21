import AVFoundation
import SwiftUI
import VisionKit

struct PairingScannerView: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraAllowed = false
    @State private var checkingPermission = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if checkingPermission {
                    ProgressView("Preparing camera…")
                } else if cameraAllowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable && error == nil {
                    PairingScannerCanvas { value in
                        onScan(value)
                        dismiss()
                    } onFailure: { error = $0 }
                    .overlay(alignment: .bottom) {
                        Text("Scan the QR code in SidecarBridge on your Mac. You will confirm before connecting.")
                            .font(.callout).padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .padding()
                    }
                } else {
                    ContentUnavailableView {
                        Label("Use the Mac code instead", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(error ?? "Camera scanning is unavailable. Close this panel and enter the 16-digit code shown on the Mac. Camera access is optional.")
                    } actions: {
                        Button("Enter Code") { dismiss() }
                        if !cameraAllowed {
                            Button("Camera Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            checkingPermission = false
        }
    }
}

private struct PairingScannerCanvas: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> PairingScannerHost {
        PairingScannerHost(onScan: onScan, onFailure: onFailure)
    }
    func updateUIViewController(_ controller: PairingScannerHost, context: Context) {}
    static func dismantleUIViewController(_ controller: PairingScannerHost, coordinator: ()) {
        controller.scanner.stopScanning()
    }
}

private final class PairingScannerHost: UIViewController, DataScannerViewControllerDelegate {
    let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isGuidanceEnabled: true,
        isHighlightingEnabled: true
    )
    private let onScan: (String) -> Void
    private let onFailure: (String) -> Void
    private var delivered = false

    init(onScan: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onScan = onScan
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() }
        catch { onFailure("Camera scanning could not start. You can still pair by entering the Mac code.") }
    }
    override func viewWillDisappear(_ animated: Bool) {
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            guard !delivered, case .barcode(let barcode) = item,
                  let value = barcode.payloadStringValue else { continue }
            delivered = true
            scanner.stopScanning()
            onScan(value)
        }
    }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        onFailure("Camera scanning is temporarily unavailable. Enter the Mac code to continue.")
    }
}
