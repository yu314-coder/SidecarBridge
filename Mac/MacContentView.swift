import AppKit
import SwiftUI

struct MacContentView: View {
    @ObservedObject var model: MacConnectionModel

    private var statusColor: Color {
        if model.isStreaming { return .green }
        if model.localNetworkPermissionNeeded { return .orange }
        if model.hasPadPeer { return .cyan }
        return .indigo
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.04, blue: 0.14), Color(red: 0.06, green: 0.08, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    statusCard
                    modeCards
                    fileTransferCard
                    permissionCard
                    startupCard
                    footer
                }
                .frame(maxWidth: 900)
                .padding(28)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .shadow(color: .blue.opacity(0.35), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text("SidecarBridge")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Your Mac screen, with the iPad keyboard and trackpad.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            Text("MAC")
                .font(.caption2.bold())
                .tracking(1.6)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: Capsule())
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusColor.opacity(0.16))
                Image(systemName: model.isStreaming ? "dot.radiowaves.left.and.right" : "ipad.and.arrow.forward")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.status)
                    .font(.title3.bold())
                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(model.isStreaming ? "LIVE" : model.hasPadPeer ? "CONNECTED" : "READY")
                    .font(.caption2.bold())
                    .tracking(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(statusColor.opacity(0.13), in: Capsule())
            .foregroundStyle(statusColor)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
    }

    private var modeCards: some View {
        HStack(spacing: 14) {
            ModeCard(
                icon: "cursorarrow.motionlines",
                title: "In-App Display",
                subtitle: "Recommended",
                description: "Encrypted same-Wi-Fi screen stream with Magic Keyboard, trackpad, touch, and Pencil input.",
                tint: .cyan,
                buttonTitle: model.isStreaming ? "Streaming" : "Start App Stream",
                isPrimary: true,
                isDisabled: !model.hasPadPeer || model.isStreaming,
                action: model.startFallback
            )

            ModeCard(
                icon: "rectangle.connected.to.line.below",
                title: "System Sidecar",
                subtitle: "Leaves this app",
                description: "Uses Apple's native Sidecar display app. Apple does not allow that stream to be embedded here.",
                tint: .purple,
                buttonTitle: "Open System Sidecar",
                isPrimary: false,
                isDisabled: false,
                action: model.trySidecarNow
            )
        }
    }

    private var permissionCard: some View {
        VStack(spacing: 0) {
            panelTitle("Permissions, P2P & pairing", icon: "checkmark.shield")
            Divider().overlay(.white.opacity(0.08))

            PermissionRow(
                icon: "network",
                title: "Local Network",
                detail: localNetworkDetail,
                isReady: model.localNetworkAccess.isGranted,
                isChecking: model.localNetworkAccess == .checking || isLocalNetworkTemporarilyUnavailable
            ) {
                if model.localNetworkPermissionNeeded {
                    Button("Allow") { model.openLocalNetworkSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            }

            Divider().overlay(.white.opacity(0.08))

            PermissionRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "P2P transport",
                detail: model.p2pDetail,
                isReady: model.p2pIsReady,
                isChecking: model.p2pIsChecking,
                stateLabel: model.p2pBadge
            ) { EmptyView() }

            Divider().overlay(.white.opacity(0.08))

            PermissionRow(
                icon: "rectangle.inset.filled.and.person.filled",
                title: "Screen Recording",
                detail: model.screenRecordingAuthorized ? "Screen capture permission passed" : "Required to send the Mac display",
                isReady: model.screenRecordingAuthorized
            ) {
                if !model.screenRecordingAuthorized {
                    Button("Allow") { model.enableScreenRecording() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            }

            Divider().overlay(.white.opacity(0.08))

            PermissionRow(
                icon: "keyboard.badge.ellipsis",
                title: "Keyboard & trackpad",
                detail: model.remoteInputAuthorized ? "Accessibility input is enabled" : "Accessibility permission required",
                isReady: model.remoteInputAuthorized
            ) {
                if !model.remoteInputAuthorized {
                    Button("Open Accessibility") { model.enableRemoteInput() }
                    Button("Show App") { model.revealApplication() }
                }
            }

            if let peer = model.pairedPeer {
                Divider().overlay(.white.opacity(0.08))
                PermissionRow(icon: "ipad", title: "Paired iPad", detail: peer, isReady: true) {
                    Button("Forget") { model.forgetPairing() }
                }
            }
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var fileTransferCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.square.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 52, height: 52)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text("Encrypted file transfer").font(.headline)
                if let transfer = model.fileTransferSnapshot {
                    Text("\(transfer.message): \(transfer.fileName)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                    ProgressView(value: transfer.progress).tint(.cyan)
                } else if let error = model.fileTransferError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Send to iPad, or receive into Downloads/SidecarBridge Transfers.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer(minLength: 12)
            if model.lastReceivedFile != nil {
                Button("Show Received") { model.revealLastReceivedFile() }
            }
            Button {
                model.chooseFileToSend()
            } label: {
                Label("Send File", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!model.hasPadPeer || model.isFileTransferring)
        }
        .padding(17)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var localNetworkDetail: String {
        switch model.localNetworkAccess {
        case .checking:
            return "Checking direct Wi-Fi and peer-to-peer access"
        case .granted:
            return "Permission passed — direct discovery is ready"
        case .denied:
            return "Permission required for same-Wi-Fi discovery"
        case .unavailable(let reason):
            return "Temporarily unavailable — \(reason)"
        }
    }

    private var isLocalNetworkTemporarilyUnavailable: Bool {
        if case .unavailable = model.localNetworkAccess { return true }
        return false
    }

    private var startupCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
                Image(systemName: "power")
                    .font(.title3.bold())
                    .foregroundStyle(model.launchAtLogin ? .green : .white.opacity(0.55))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic startup").font(.headline)
                Text(model.launchAtLoginDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()

            if model.launchAtLoginNeedsApproval {
                Button("Open Login Items") { model.openLoginItemsSettings() }
                    .buttonStyle(.borderedProminent)
            } else if model.launchAtLogin {
                Button("Repair") { model.repairLaunchAtLogin() }
                Button("Turn Off") { model.setLaunchAtLogin(false) }
            } else {
                Button("Start Automatically") { model.setLaunchAtLogin(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var footer: some View {
        HStack {
            Label("Local and encrypted", systemImage: "lock.fill")
            Spacer()
            Button("Displays Settings") { model.openDisplaysSettings() }
                .buttonStyle(.link)
            if !model.reachableSidecarDevices.isEmpty {
                Text("Apple Sidecar: \(model.reachableSidecarDevices.joined(separator: ", "))")
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 4)
    }

    private func panelTitle(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.headline)
            Spacer()
        }
        .padding(16)
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let tint: Color
    let buttonTitle: String
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                Spacer()
                Text(subtitle.uppercased())
                    .font(.caption2.bold())
                    .tracking(0.8)
                    .foregroundStyle(tint)
            }
            Text(title).font(.title3.bold())
            Text(description)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isPrimary {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(isDisabled)
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(tint)
                    .disabled(isDisabled)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(
            LinearGradient(colors: [tint.opacity(0.12), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.22)))
    }
}

private struct PermissionRow<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    let isReady: Bool
    let isChecking: Bool
    let stateLabel: String?
    let actions: Actions

    init(
        icon: String,
        title: String,
        detail: String,
        isReady: Bool,
        isChecking: Bool = false,
        stateLabel: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.isReady = isReady
        self.isChecking = isChecking
        self.stateLabel = stateLabel
        self.actions = actions()
    }

    private var stateColor: Color {
        if isReady { return .green }
        if isChecking { return .cyan }
        return .orange
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(stateColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            actions
            Text(stateLabel ?? (isReady ? "PASSED" : isChecking ? "CHECKING" : "ACTION"))
                .font(.caption2.bold())
                .tracking(0.7)
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(stateColor.opacity(0.12), in: Capsule())
            Image(systemName: isReady ? "checkmark.circle.fill" : isChecking ? "ellipsis.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
