import SwiftUI

/// Shared instructions deliberately avoid automatic "passed" checks. Public
/// APIs don't establish USB trust, Apple Account equality, or Sidecar readiness.
struct NativeSidecarGuide: View {
    @Binding var route: NativeSidecarRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Apple's display, outside this app", systemImage: "ipad.landscape")
                .font(.headline)
            Text("Mirror or extend your desktop in Apple's separate Sidecar display. No SidecarBridge pairing or Mac companion app is required for this native route.")
                .font(.callout).foregroundStyle(.secondary)

            Picker("Setup route", selection: $route) {
                ForEach(NativeSidecarRoute.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Chooses instructions, not the active network transport.")

            instruction("1", title: "Check your Apple Account", detail: "Both devices need the same Apple Account with two-factor authentication.")
            instruction("2", title: route.title, detail: route.instructions)
            instruction("3", title: "Select your iPad on the Mac", detail: "Open System Settings → Displays → Add Display (+), then choose your iPad. Control Center → Screen Mirroring is another entry point.")

            Text("Same internet is not enough. Apple checks device compatibility and connection requirements; this app cannot verify those checks or force a cable route.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Label("Keyboard and pointer differences", systemImage: "keyboard")
                .font(.subheadline.bold())
            Text("The iPad keyboard works in native Sidecar. For pointing, Apple supports a mouse/trackpad attached to the Mac, or Apple Pencil. Use In-App Display for this app's iPad trackpad and touch controls.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Apple's Sidecar requirements and help", destination: URL(string: "https://support.apple.com/en-us/102597")!)
                .font(.callout)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold())
                .frame(width: 26, height: 26)
                .background(.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
