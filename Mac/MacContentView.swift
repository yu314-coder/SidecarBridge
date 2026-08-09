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
                    quickActionsCard
                    modeCards
                    #if !SIDECARBRIDGE_APP_STORE_SAFE
                    shortcutTestCard
                    #endif
                    fileTransferCard
                    permissionCard
                    systemInformationCard
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

    #if !SIDECARBRIDGE_APP_STORE_SAFE
    private var shortcutTestCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Mission Control shortcut test", systemImage: "keyboard")
                    .font(.headline)
                Text(model.shortcutTestStatus)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            ForEach(["left", "right", "down", "up"], id: \.self) { key in
                Button("⌃\(arrow(for: key))") { model.testControlShortcut(key) }
                    .buttonStyle(.bordered)
                    .help("Inject Control-\(arrow(for: key)) locally")
            }
            Button("⌥Click") { model.testModifierClick(["option"]) }
                .buttonStyle(.bordered)
                .help("Inject an Option-click at the current Mac pointer")
            Button("⇧Click") { model.testModifierClick(["shift"]) }
                .buttonStyle(.bordered)
                .help("Inject a Shift-click at the current Mac pointer")
            Button("⌥⇧Click") { model.testModifierClick(["option", "shift"]) }
                .buttonStyle(.bordered)
                .help("Inject an Option-Shift-click at the current Mac pointer")
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private func arrow(for key: String) -> String {
        ["left": "←", "right": "→", "down": "↓", "up": "↑"][key] ?? key
    }
    #endif

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
                #if SIDECARBRIDGE_APP_STORE_SAFE
                Text("Your screen on iPad, with a private local connection.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.62))
                #else
                Text("Your Mac screen, with the iPad keyboard and trackpad.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.62))
                #endif
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

    private var quickActionsCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                quickActionButtons
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                quickActionButtons
            }
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        Button {
            if model.isStreaming {
                model.stopFallback()
            } else {
                model.startFallback()
            }
        } label: {
            Label(
                model.isStreaming ? "Stop Stream" : "Start Stream",
                systemImage: model.isStreaming ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isStreaming ? .orange : .cyan)
        .disabled(!model.hasPadPeer && !model.isStreaming)
        .keyboardShortcut("s", modifiers: [.command, .option])

        Button {
            model.chooseFileToSend()
        } label: {
            Label("Send Files…", systemImage: "paperplane.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!model.hasPadPeer)
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Button {
            model.openTransferFolder()
        } label: {
            Label("Transfers", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("f", modifiers: [.command, .option])

        Button {
            model.copyDiagnosticReport()
        } label: {
            Label("Copy Report", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }

    private var modeCards: some View {
        HStack(spacing: 14) {
            ModeCard(
                icon: "cursorarrow.motionlines",
                title: "In-App Display",
                subtitle: "Recommended",
                description: inAppDisplayDescription,
                tint: .cyan,
                buttonTitle: model.isStreaming ? "Streaming" : "Start App Stream",
                isPrimary: true,
                isDisabled: !model.hasPadPeer || model.isStreaming,
                action: model.startFallback
            )

            ModeCard(
                icon: "rectangle.connected.to.line.below",
                title: systemDisplayTitle,
                subtitle: "Public system UI",
                description: systemDisplayDescription,
                tint: .purple,
                buttonTitle: "Open Displays Settings",
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
                icon: "arrow.down.left.and.arrow.up.right",
                title: "Incoming encrypted connection",
                detail: model.incomingListenerDetail,
                isReady: model.incomingListenerReady,
                isChecking: !model.incomingListenerReady,
                stateLabel: model.incomingListenerReady ? "LISTENING" : "STARTING"
            ) { EmptyView() }

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
                icon: "waveform.path.ecg",
                title: "Connection health",
                detail: connectionHealthText,
                isReady: model.hasPadPeer && model.connectionHealthDetail == "Encrypted link healthy",
                isChecking: model.hasPadPeer && model.connectionHealthDetail != "Encrypted link healthy",
                stateLabel: model.connectionLatencyMS.map { "\($0) MS" } ?? (model.hasPadPeer ? "VERIFYING" : "WAITING")
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

            #if !SIDECARBRIDGE_APP_STORE_SAFE
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
            #else
            Divider().overlay(.white.opacity(0.08))
            PermissionRow(
                icon: "rectangle.on.rectangle",
                title: "Mac App Store viewer edition",
                detail: "Remote keyboard and trackpad control is provided by the direct companion build.",
                isReady: true,
                stateLabel: "VIEWER"
            ) { EmptyView() }
            #endif

            Divider().overlay(.white.opacity(0.08))

            PermissionRow(
                icon: "lock.badge.clock",
                title: "First-time secure pairing code",
                detail: "\(model.pairingCode) • 16 characters, expires after five minutes, and is replaced by a Keychain credential.",
                isReady: true,
                stateLabel: "ONE-TIME"
            ) {
                Button("Copy") { model.copyPairingCode() }
            }

            if let peer = model.pairedPeer {
                Divider().overlay(.white.opacity(0.08))
                PermissionRow(icon: "ipad.and.iphone", title: "Authorized devices", detail: peer, isReady: true) {
                    Button("Forget All") { model.forgetPairing() }
                }
            }
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var inAppDisplayDescription: String {
        #if SIDECARBRIDGE_APP_STORE_SAFE
        return "Encrypted same-Wi-Fi screen stream for private viewing on iPad."
        #else
        return "Encrypted same-Wi-Fi screen stream with Magic Keyboard, trackpad, touch, and Pencil input."
        #endif
    }

    private var systemDisplayTitle: String {
        #if SIDECARBRIDGE_APP_STORE_SAFE
        return "System Display Settings"
        #else
        return "System Sidecar"
        #endif
    }

    private var systemDisplayDescription: String {
        #if SIDECARBRIDGE_APP_STORE_SAFE
        return "Opens the system display settings. This companion uses only public APIs."
        #else
        return "Opens Displays settings so you can choose Apple Sidecar. The direct companion uses public APIs for this system action."
        #endif
    }

    private var fileTransferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Text(transfer.byteProgressDescription)
                            if let rate = transfer.transferRateDescription { Text(rate) }
                            if let remaining = transfer.remainingTimeDescription { Text(remaining) }
                            if model.queuedFileCount > 0 { Text("+\(model.queuedFileCount) queued") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.52))
                        ProgressView(value: transfer.progress).tint(.cyan)
                    } else if let error = model.fileTransferError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Send one or more files to the iPad, or receive into Downloads/SidecarBridge Transfers.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.chooseFileToSend()
                } label: {
                    Label("Send Files…", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!model.hasPadPeer)

                Button {
                    model.openTransferFolder()
                } label: {
                    Label("Open Transfers", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if model.lastReceivedFile != nil {
                    Button("Show Received") { model.revealLastReceivedFile() }
                        .buttonStyle(.bordered)
                }

                if model.isFileTransferring || model.queuedFileCount > 0 {
                    Button("Cancel", role: .destructive) { model.cancelFileTransfer() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(17)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var systemInformationCard: some View {
        VStack(spacing: 0) {
            panelTitle("System information & diagnostics", icon: "info.circle")
            Divider().overlay(.white.opacity(0.08))

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    SystemInformationPanel(
                        title: "This Mac",
                        subtitle: "Local system",
                        information: model.localSystemInformation,
                        tint: .cyan
                    )
                    SystemInformationPanel(
                        title: "Connected device",
                        subtitle: model.hasPadPeer ? "Encrypted peer snapshot" : "Connect to retrieve",
                        information: model.remoteSystemInformation,
                        tint: .purple
                    )
                }
                VStack(spacing: 14) {
                    SystemInformationPanel(
                        title: "This Mac",
                        subtitle: "Local system",
                        information: model.localSystemInformation,
                        tint: .cyan
                    )
                    SystemInformationPanel(
                        title: "Connected device",
                        subtitle: model.hasPadPeer ? "Encrypted peer snapshot" : "Connect to retrieve",
                        information: model.remoteSystemInformation,
                        tint: .purple
                    )
                }
            }
            .padding(16)

            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 12) {
                Label(model.diagnosticActionDetail, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Button {
                    model.refreshSystemInformation()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    model.copyDiagnosticReport()
                } label: {
                    Label("Copy Report", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
            .padding(16)
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var connectionHealthText: String {
        guard let latency = model.connectionLatencyMS else { return model.connectionHealthDetail }
        return "\(model.connectionHealthDetail) • round trip \(latency) ms"
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
        VStack(spacing: 14) {
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

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
                    Image(systemName: model.shutdownProtectionActive
                          ? "shield.lefthalf.filled.badge.checkmark"
                          : "shield.checkered")
                        .font(.title3.bold())
                        .foregroundStyle(model.shutdownProtectionEnabled ? .cyan : .white.opacity(0.55))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Shutdown handoff").font(.headline)
                    Text(model.shutdownProtectionDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Pre-login control is unavailable: macOS starts App Store login items only after authentication.")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.shutdownProtectionEnabled },
                        set: { model.setShutdownProtectionEnabled($0) }
                    )
                )
                .labelsHidden()
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
            #if !SIDECARBRIDGE_APP_STORE_SAFE
            if !model.reachableSidecarDevices.isEmpty {
                Text("Apple Sidecar: \(model.reachableSidecarDevices.joined(separator: ", "))")
            }
            #endif
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

private struct SystemInformationPanel: View {
    let title: String
    let subtitle: String
    let information: SystemInformation?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: information == nil ? "questionmark.circle" : "desktopcomputer")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if let information {
                    Text(information.platform.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.12), in: Capsule())
                }
            }

            if let information {
                ForEach(Array(information.summaryRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.name)
                            .foregroundStyle(.white.opacity(0.52))
                        Spacer()
                        Text(row.value)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            } else {
                Text("The connected iPhone or iPad will send this information after secure authentication.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.15)))
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
