import SwiftUI

struct MacPairingCard: View {
    let invitation: PairingInvitation
    var enlarged = false
    let copyCode: () -> Void
    var enlarge: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Connect a device", systemImage: "ipad.and.iphone")
                        .font(.title2.bold())
                    Text(invitation.name).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label("Private pairing", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.cyan)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) {
                    instructions.frame(width: enlarged ? 430 : 360, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    qr
                }
                VStack(alignment: .leading, spacing: 22) {
                    instructions
                    qr.frame(maxWidth: .infinity)
                }
            }
            Divider().overlay(.white.opacity(0.08))
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").foregroundStyle(.cyan)
                Text("Pair once. Your trusted device is remembered. Scanning fills the form—tap Connect on your iPad or iPhone to start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Can't scan? Connection help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter the code above with or without dashes. Open SidecarBridge on both devices and allow Local Network access. Refreshing this code does not forget trusted devices.")
                    if !invitation.hosts.isEmpty {
                        Text("Manual Mac address: \(invitation.hosts.joined(separator: " · "))")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
        .padding(enlarged ? 30 : 24)
        .background(.cyan.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.cyan.opacity(0.25)))
        .onChange(of: invitation.code) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            copied = false
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Scan from SidecarBridge", systemImage: "qrcode.viewfinder")
                .font(.headline)
            Text("On your iPad or iPhone, tap Scan Mac Code and point the camera here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("OR ENTER THE 16-DIGIT CODE")
                .font(.caption2.bold()).tracking(1.2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(PairingCode.formatted(invitation.code).split(separator: "-").enumerated()), id: \.offset) { _, group in
                    Text(String(group))
                        .font(.system(size: enlarged ? 34 : 26, weight: .semibold, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 12)
                        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pairing code")
            .accessibilityValue(invitation.code.map(String.init).joined(separator: " "))
            Button {
                copyCode()
                copied = true
            } label: {
                Label(copied ? "Code copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent).tint(.cyan).controlSize(.large)
            .accessibilityHint("Copies all 16 digits with dashes for manual pairing.")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(invitation.expiresAt.timeIntervalSince(context.date)))
                Label(seconds > 0 ? "Refreshes in \(seconds / 60):\(String(format: "%02d", seconds % 60))" : "Refreshing code…", systemImage: "clock")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var qr: some View {
        VStack(spacing: 10) {
            PairingQRCodeView(payload: invitation.encoded, size: enlarged ? 300 : 224)
            if let enlarge {
                Button(action: enlarge) { Label("Enlarge QR", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.bordered)
            }
        }
    }
}
