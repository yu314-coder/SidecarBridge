import SwiftUI

struct PadNativeSidecarSetupView: View {
    @ObservedObject var model: PadConnectionModel
    let onOpenRemoteControl: () -> Void

    var body: some View {
        Form {
            Section {
                NativeSidecarGuide(route: $model.nativeSidecarRoute)
            }
            Section("Optional setup shortcut") {
                if model.isConnected {
                    Label("Paired with \(model.selectedMacName ?? "your Mac")", systemImage: "lock.shield")
                        .font(.subheadline)
                    Button(action: model.requestSystemSidecar) {
                        HStack {
                            Label("Open Displays on Mac", systemImage: "display")
                            if model.nativeSidecarProgress.isRequesting { ProgressView() }
                        }
                    }
                    .disabled(model.nativeSidecarProgress.isRequesting)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.nativeSidecarProgress.title).font(.subheadline.bold())
                        Text(model.nativeSidecarProgress.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("nativeSidecarSetupStatus")
                } else {
                    Text("No app connection is needed to follow the steps above. To open the Mac's settings from this button, first connect to the Mac app securely.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    model.returnToInAppDisplay()
                    onOpenRemoteControl()
                } label: {
                    Label(model.isStreaming ? "Return to In-App Display" : "Use In-App Display", systemImage: "cursorarrow.motionlines")
                }
                .disabled(!model.isConnected)
            } footer: {
                Text("If you are streaming, return to the Mac screen to select your iPad in Displays. Opening this guide does not stop the stream or clear saved trust. Apple manages the native display separately; this app cannot embed it or confirm it connected.")
            }
        }
        .navigationTitle("Apple Sidecar setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
