import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum PadRootTab {
    case remoteControl
    case settings
}

struct PadContentView: View {
    @ObservedObject var model: PadConnectionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlDrawerOpen = false
    @State private var showingFileImporter = false
    @State private var viewerScale: CGFloat = 1
    @State private var viewerOffset: CGSize = .zero
    // The Mac cursor is embedded in the captured frame. Keeping a second
    // iPad-drawn cursor causes visible drift, especially while the stream is
    // under load, so the local cursor is permanently disabled.
    @State private var showVirtualCursor = false
    @State private var showMagicKeyboardPointer: Bool = {
        UserDefaults.standard.object(forKey: "showMagicKeyboardPointer") as? Bool ?? false
    }()
    @State private var showClickFeedback: Bool = {
        UserDefaults.standard.object(forKey: "showClickFeedback") as? Bool ?? true
    }()
    @State private var showTopStatusBar: Bool = {
        UserDefaults.standard.object(forKey: "showTopStatusBar") as? Bool ?? true
    }()
    @State private var showBottomHint: Bool = {
        UserDefaults.standard.object(forKey: "showBottomHint") as? Bool ?? true
    }()
    @State private var pointerButtonMapping: RemotePointerButtonMapping = {
        guard let rawValue = UserDefaults.standard.string(forKey: "pointerButtonMapping"),
              let mapping = RemotePointerButtonMapping(rawValue: rawValue) else { return .system }
        return mapping
    }()
    @State private var isCalibratingPointerButtons = false
    @State private var showsSoftwareKeyboard = false
    // These are retained for the streaming drawer's legacy actions; the
    // dashboard no longer exposes diagnostics or destructive actions.
    @State private var showingForgetConfirmation = false
    @State private var showingSystemInformation = false
    @State private var selectedTab: PadRootTab = .remoteControl

    private var content: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.018, green: 0.025, blue: 0.09), Color(red: 0.06, green: 0.035, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if model.isStreaming {
                streamingView
                // Keep the viewer mounted behind Settings so the same sample
                // buffer layer remains the Picture-in-Picture source. The
                // settings panel is drawn above it and does not start a new
                // viewer coordinate space.
                if selectedTab == .settings {
                    settingsPanel
                }
            } else if selectedTab == .settings {
                settingsPanel
            } else {
                dashboard
            }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        .onChange(of: showVirtualCursor) { _, value in
            UserDefaults.standard.set(value, forKey: "showVirtualCursor")
        }
        .onChange(of: showClickFeedback) { _, value in
            UserDefaults.standard.set(value, forKey: "showClickFeedback")
        }
        .onChange(of: showTopStatusBar) { _, value in
            UserDefaults.standard.set(value, forKey: "showTopStatusBar")
        }
        .onChange(of: showBottomHint) { _, value in
            UserDefaults.standard.set(value, forKey: "showBottomHint")
        }
        .onChange(of: model.isStreaming) { _, streaming in
            if !streaming { resetViewerZoom() }
        }
    }

    var body: some View {
        content
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { handleFileImport($0) }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first { model.sendFile(at: url) }
        case .failure(let error):
            model.fileTransferError = error.localizedDescription
        }
    }

    private var dashboard: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 24) {
                            Color.clear.frame(height: 1).id("dashboard-top")
                            header
                            connectionCard
                            if model.isConnected {
                                connectedSessionCard
                                permissionStrip
                                modeChooser

                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top, spacing: 14) {
                                        fileTransferCard
                                        clipboardCard
                                    }
                                    VStack(spacing: 14) {
                                        fileTransferCard
                                        clipboardCard
                                    }
                                }

                                systemInformationCard
                            } else {
                                macSelectionPanel
                                connectActionCard
                                requirementStrip

                                if visibleMacNames.isEmpty || model.isConnecting || model.pairingRequired || model.isDiscoveryTakingLonger || model.localNetworkPermissionNeeded {
                                    discoveryCard
                                }
                            }
                        }
                        .frame(maxWidth: 920)
                        .frame(minHeight: geometry.size.height - 48)
                        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 36)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                    }

                    rootTabBar {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo("dashboard-top", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private func rootTabBar(remoteAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: remoteAction) {
                Label("Remote Control", systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedTab == .remoteControl ? .cyan : .white.opacity(0.78))
            .accessibilityHint("Return to the connection and remote-control dashboard.")

            Button { selectedTab = .settings } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedTab == .settings ? .cyan : .white.opacity(0.78))
            .accessibilityHint("Open connection, viewer, keyboard, and pointer settings.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 36)
        .padding(.bottom, 10)
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            PadSettingsPanel(
                model: model,
                showVirtualCursor: $showVirtualCursor,
                showClickFeedback: $showClickFeedback,
                showTopStatusBar: $showTopStatusBar,
                showBottomHint: $showBottomHint,
                showsSoftwareKeyboard: $showsSoftwareKeyboard,
                pointerButtonMapping: $pointerButtonMapping,
                isCalibratingPointerButtons: $isCalibratingPointerButtons,
                showingFileImporter: $showingFileImporter,
                onOpenRemoteControl: { selectedTab = .remoteControl }
            )
            rootTabBar { selectedTab = .remoteControl }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                headerIdentity
                Spacer()
                headerActions
            }
            VStack(alignment: .leading, spacing: 14) {
                headerIdentity
                headerActions
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 9) {
            securityBadge
            Button {
                selectedTab = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityHint("Open connection, viewer, keyboard, and pointer settings.")
        }
    }

    private var headerIdentity: some View {
        HStack(spacing: horizontalSizeClass == .compact ? 12 : 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(
                    width: horizontalSizeClass == .compact ? 58 : 82,
                    height: horizontalSizeClass == .compact ? 58 : 82
                )
                .clipShape(RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 15 : 20, style: .continuous))
                .shadow(color: .blue.opacity(0.35), radius: 18, y: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("SidecarBridge")
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)
                    .minimumScaleFactor(0.8)
                Text("A secure remote window into your Mac")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var securityBadge: some View {
        Label("LOCAL + ENCRYPTED", systemImage: "lock.fill")
            .font(.caption.bold())
            .foregroundStyle(.cyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.cyan.opacity(0.14), in: Capsule())
            .accessibilityLabel("Local encrypted connection")
    }

    private var connectedSessionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.green.opacity(0.15))
                    Image(systemName: model.isStreaming ? "rectangle.inset.filled" : "desktopcomputer")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isStreaming ? "Mac screen is live" : "Mac is connected")
                        .font(.title3.bold())
                    Text(model.selectedMacName ?? "Selected Mac")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                    Text(model.isStreaming
                         ? "Use touch, trackpad, Magic Keyboard, or Pencil in the viewer."
                         : "The secure link is ready. Start the in-app display when you are ready.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(model.isStreaming ? "LIVE" : "READY")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 8) {
                connectionMetric(
                    title: "Transport",
                    value: model.connectedUsingDirectLAN ? "Direct LAN" : "P2P",
                    icon: "point.3.connected.trianglepath.dotted",
                    tint: .cyan
                )
                connectionMetric(
                    title: "Latency",
                    value: model.connectionLatencyMS.map { "\($0) ms" } ?? "Checking",
                    icon: "waveform.path.ecg",
                    tint: .green
                )
                connectionMetric(
                    title: "Input",
                    value: model.remoteInputAuthorized ? "Ready" : "Permission",
                    icon: "cursorarrow.motionlines",
                    tint: model.remoteInputAuthorized ? .green : .orange
                )
            }

            Button {
                model.requestFallback()
            } label: {
                Label(
                    model.isStreaming ? "In-App Display Active" : "Start In-App Display",
                    systemImage: model.isStreaming ? "checkmark.circle.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .controlSize(.large)
            .disabled(model.isStreaming)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [.green.opacity(0.14), .cyan.opacity(0.08), .white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.green.opacity(0.26)))
    }

    private func connectionMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var connectionCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                connectionStatusIcon
                connectionStatusText
                Spacer(minLength: 12)
                connectionModeSummary
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    connectionStatusIcon
                    connectionStatusText
                }
                connectionModeSummary
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var connectionStatusIcon: some View {
        ZStack {
            Circle().fill(statusColor.opacity(0.16))
            Image(systemName: statusIcon)
                .font(.title2.bold())
                .foregroundStyle(statusColor)
        }
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
    }

    private var connectionStatusText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sessionSummaryTitle)
                .font(.title2.bold())
            Text(sessionSummaryDetail)
                .font(.body)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionModeSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                model.isConnected ? "MAC CONNECTED" : "NOT CONNECTED",
                systemImage: model.isConnected ? "checkmark.circle.fill" : "pause.circle"
            )
            .font(.caption.bold())
            .foregroundStyle(statusColor)
            Text(model.preferTrackpadControl ? "In-App Display mode" : "System Sidecar mode")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.74))
        }
    }

    private var connectActionCard: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.isConnecting ? "Connecting…" : "Ready to connect")
                    .font(.headline)
                Text(model.selectedMacName.map { "Connect to \($0) with full keyboard and trackpad control." } ?? "Select a device to continue.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                model.connectSelectedMac()
            } label: {
                Group {
                    if model.isConnecting {
                        Label("Connecting…", systemImage: "hourglass")
                    } else {
                        Label("Connect", systemImage: "play.fill")
                    }
                }
                .font(.headline)
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(model.selectedMacName == nil || model.isConnected || model.isConnecting)
        }
        .padding(17)
        .background(
            LinearGradient(
                colors: [.cyan.opacity(0.18), .white.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(.cyan.opacity(0.26)))
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    discoveryIdentity
                    Spacer(minLength: 12)
                    discoveryAttemptControls
                }
                VStack(alignment: .leading, spacing: 14) {
                    discoveryIdentity
                    HStack {
                        discoveryAttemptControls
                        Spacer()
                    }
                }
            }

            Divider().overlay(.white.opacity(0.08))

            if model.pairingRequired {
                Divider().overlay(.white.opacity(0.08))
                pairingCodePanel
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { discoveryPathTiles }
                VStack(spacing: 12) { discoveryPathTiles }
            }

            if model.localNetworkPermissionNeeded || model.isDiscoveryTakingLonger {
                discoveryRecoveryPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke((model.localNetworkPermissionNeeded ? Color.orange : Color.cyan).opacity(0.22))
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.isDiscoveryTakingLonger)
    }

    private var visibleMacNames: [String] {
        var names = model.discoveredMacs
        if let selected = model.selectedMacName, !names.contains(selected) {
            names.insert(selected, at: 0)
        }
        return names
    }

    private var macSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("My Devices", systemImage: "rectangle.3.group")
                    .font(.headline)
                Spacer()
                Text(visibleMacNames.isEmpty ? (model.isConnecting ? "Connecting" : "Searching") : "\(visibleMacNames.count) found")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.55))
                Button {
                    model.retry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.bold())
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Refresh device list")
            }
            if visibleMacNames.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.cyan)
                    Text("Searching cable, local network, and nearby peer-to-peer…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            } else {
                ForEach(visibleMacNames, id: \.self, content: macDeviceCard)
            }
        }
        .padding(16)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
    }

    private func macDeviceCard(_ name: String) -> some View {
        let isSelected = model.selectedMacName == name
        let isConnected = model.isConnected && isSelected
        let isRemembered = isSelected && !model.discoveredMacs.contains(name)
        let subtitle = isConnected
            ? "Connected — keyboard and trackpad are available"
            : isRemembered
                ? "Saved on this iPad — tap Connect to try the local paths"
                : isSelected
                    ? "Selected — ready to connect"
                    : "Available — tap the card to select"

        return HStack(spacing: 12) {
            Button {
                model.chooseMac(name)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isConnected ? "desktopcomputer.and.arrow.forward" : "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(isConnected ? .green : .cyan)
                        .frame(width: 44, height: 44)
                        .background((isConnected ? Color.green : Color.cyan).opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mac \(name)")
            .accessibilityHint(isSelected ? "Selected. Use Connect to start the session." : "Select this Mac without connecting.")

            Button {
                if !isSelected { model.chooseMac(name) }
                model.connectSelectedMac()
            } label: {
                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                } else if model.isConnecting && isSelected {
                    Label("Connecting…", systemImage: "hourglass")
                } else {
                    Label("Connect", systemImage: "arrow.right.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? .green : .cyan)
            .controlSize(.small)
            .disabled(isConnected || model.isConnecting)
        }
        .padding(12)
        .background(.white.opacity(isSelected ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isSelected ? .cyan.opacity(0.52) : .white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var pairingCodePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("First-time secure pairing", systemImage: "lock.badge.clock")
                .font(.headline)
                .foregroundStyle(.cyan)
            Text("Enter the 16-digit code shown by SidecarBridge on \(model.pairingMacName), including the dashes. They are inserted automatically as you type. It expires after five minutes and is replaced by a Keychain credential.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                SecureField("0000-0000-0000-0000", text: pairingCodeFieldBinding)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { model.submitPairingCode() }

                Button("Trust This Mac") { model.submitPairingCode() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            }

            if let error = model.pairingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.cyan.opacity(0.22)))
    }

    private var pairingCodeFieldBinding: Binding<String> {
        Binding(
            get: { model.pairingCode },
            set: { model.pairingCode = PairingCode.formattedInput($0) }
        )
    }

    private var discoveryIdentity: some View {
        HStack(alignment: .center, spacing: 16) {
            MacDiscoveryPulse(
                tint: model.localNetworkPermissionNeeded ? .orange : .cyan,
                reduceMotion: reduceMotion
            )
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.localNetworkPermissionNeeded ? "Discovery needs permission" : "Looking for your Mac")
                    .font(.title2.bold())
                Text(discoveryDetail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var discoveryAttemptControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ATTEMPT \(model.discoveryAttempt)")
                .font(.caption.bold())
                .foregroundStyle(model.localNetworkPermissionNeeded ? .orange : .cyan)
            Text(searchElapsedText)
                .font(.system(.body, design: .monospaced).bold())
                .accessibilityLabel("Search time \(model.discoveryElapsedSeconds) seconds")
            Button {
                model.retry()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var discoveryPathTiles: some View {
        DiscoveryPathTile(
            icon: "network",
            title: "Local Network",
            detail: localNetworkDetail,
            state: localNetworkBadge,
            tint: localNetworkTint,
            isActive: model.localNetworkAccess == .checking
        )

        DiscoveryPathTile(
            icon: "wifi",
            title: "Same Wi-Fi + AWDL",
            detail: model.localNetworkPermissionNeeded ? "Waiting for permission" : "Searching for the Mac service",
            state: model.localNetworkPermissionNeeded ? "WAITING" : "SEARCHING",
            tint: model.localNetworkPermissionNeeded ? .secondary : .cyan,
            isActive: !model.localNetworkPermissionNeeded
        )

        DiscoveryPathTile(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Nearby P2P fallback",
            detail: model.nearbyDiscoveryIsActive ? "Bluetooth-assisted encrypted discovery" : "Starts automatically after 2 seconds",
            state: model.nearbyDiscoveryIsActive ? "SEARCHING" : "NEXT",
            tint: model.nearbyDiscoveryIsActive ? .purple : .secondary,
            isActive: model.nearbyDiscoveryIsActive
        )
    }

    private var discoveryRecoveryPanel: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.localNetworkPermissionNeeded ? "exclamationmark.shield.fill" : "wrench.and.screwdriver.fill")
                .font(.title3)
                .foregroundStyle(model.localNetworkPermissionNeeded ? .orange : .cyan)
                .frame(width: 38, height: 38)
                .background((model.localNetworkPermissionNeeded ? Color.orange : Color.cyan).opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                Text(model.localNetworkPermissionNeeded ? "Allow discovery in Settings" : "Still searching — check the Mac")
                    .font(.callout.bold())
                Text(discoveryRecoveryText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if model.localNetworkPermissionNeeded {
                Button("Open Settings") { model.openAppSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else {
                Button("Search Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            }
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Choose how to use this device")
                        .font(.headline)
                    Spacer()
                    Text("IN-APP DISPLAY RECOMMENDED")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose how to use this device")
                        .font(.headline)
                    Text("IN-APP DISPLAY RECOMMENDED")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { modeButtons }
                VStack(spacing: 14) { modeButtons }
            }
        }
    }

    private var permissionStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { permissionTiles }
            VStack(spacing: 12) { permissionTiles }
        }
    }

    private var systemInformationCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                systemInformationIdentity
                Spacer()
                systemInformationActions
            }
            VStack(alignment: .leading, spacing: 14) {
                systemInformationIdentity
                systemInformationActions
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.07)))
    }

    private var systemInformationIdentity: some View {
        HStack(spacing: 13) {
            Image(systemName: "info.circle.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 46, height: 46)
                .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("System information & diagnostics").font(.headline)
                Text(
                    model.remoteSystemInformation == nil
                        ? "\(model.localSystemInformation.deviceModel) • connect to retrieve Mac details"
                        : "\(model.localSystemInformation.deviceModel) • \(model.remoteSystemInformation?.deviceModel ?? "Mac")"
                )
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                Text(model.diagnosticActionDetail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var systemInformationActions: some View {
        HStack(spacing: 9) {
            Button {
                model.refreshSystemInformation()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            Button {
                showingSystemInformation = true
            } label: {
                Label("View Details", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
    }

    @ViewBuilder
    private var permissionTiles: some View {
        PadPermissionTile(
            icon: "network",
            title: "Local Network",
            detail: localNetworkDetail,
            state: localNetworkBadge,
            tint: localNetworkTint
        )

        PadPermissionTile(
            icon: "point.3.connected.trianglepath.dotted",
            title: "P2P transport",
            detail: model.connectionTransport,
            state: model.isConnected ? "ACTIVE" : "PRIORITY",
            tint: model.isConnected ? .green : .cyan
        )

        PadPermissionTile(
            icon: "waveform.path.ecg",
            title: "Connection health",
            detail: model.connectionHealthDetail,
            state: model.connectionLatencyMS.map { "\($0) MS" } ?? (model.isConnected ? "VERIFYING" : "WAITING"),
            tint: model.connectionLatencyMS == nil ? .cyan : .green
        )
    }

    @ViewBuilder
    private var modeButtons: some View {
        PadModeCard(
            icon: "cursorarrow.motionlines",
            title: "In-App Display",
            description: "Stays inside this app with Magic Keyboard, trackpad, touch, and Pencil control over an encrypted direct link.",
            badge: "FULL INPUT",
            tint: .cyan,
            isSelected: model.preferTrackpadControl
        ) {
            model.setPreferTrackpadControl(true)
        }

        if supportsSystemSidecar {
            PadModeCard(
                icon: "rectangle.connected.to.line.below",
                title: "System Sidecar",
                description: "Apple's native display session opens its separate Sidecar app and suspends this app.",
                badge: "LEAVES APP",
                tint: .purple,
                isSelected: !model.preferTrackpadControl
            ) {
                model.setPreferTrackpadControl(false)
            }
        }
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                actionButtons
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            model.retry()
        } label: {
            Label("Search Again", systemImage: "arrow.clockwise")
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Button {
            if model.preferTrackpadControl || !supportsSystemSidecar {
                model.requestFallback()
            } else {
                model.requestSystemSidecar()
            }
        } label: {
            Label(
                model.preferTrackpadControl || !supportsSystemSidecar ? "Start In-App Display" : "Open System Sidecar",
                systemImage: model.preferTrackpadControl || !supportsSystemSidecar ? "play.fill" : "rectangle.connected.to.line.below"
            )
            .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .controlSize(.large)
        .disabled(!model.isConnected)

        if model.localNetworkPermissionNeeded {
            Button {
                model.openAppSettings()
            } label: {
                Label("Allow Local Network", systemImage: "exclamationmark.shield")
                    .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }

        Button(role: .destructive) {
            showingForgetConfirmation = true
        } label: {
            Label("Forget Trusted Macs", systemImage: "trash")
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var requirementStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                requirementPills
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                requirementPills
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var requirementPills: some View {
        RequirementPill(icon: "wifi", text: "Local link + AWDL")
        RequirementPill(icon: "lock.fill", text: "Encrypted link")
        if supportsSystemSidecar {
            RequirementPill(icon: "keyboard", text: "Magic Keyboard")
            RequirementPill(icon: "rectangle.and.hand.point.up.left", text: "Trackpad + touch")
        } else {
            RequirementPill(icon: "hand.tap", text: "Touch controls")
        }
    }

    private var fileTransferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.cyan)
                    .frame(width: 48, height: 48)
                    .background(.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Encrypted file transfer").font(.headline)
                    if let transfer = model.fileTransferSnapshot {
                        Text("\(transfer.message): \(transfer.fileName)")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        ProgressView(value: transfer.progress)
                            .tint(.cyan)
                            .accessibilityValue("\(Int(transfer.progress * 100)) percent")
                    } else if let error = model.fileTransferError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Transfer through the same encrypted local connection used by the display.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    fileTransferButtons
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 10) {
                    fileTransferButtons
                }
            }
        }
        .padding(17)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.purple)
                    .frame(width: 48, height: 48)
                    .background(.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Clipboard transfer").font(.headline)
                    Text("Copy text from the Mac or send the current iPad clipboard. Nothing syncs automatically.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { clipboardButtons; Spacer() }
                VStack(alignment: .leading, spacing: 10) { clipboardButtons }
            }

            Text(model.clipboardTransferStatus)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(17)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    @ViewBuilder
    private var clipboardButtons: some View {
        Button {
            model.requestMacClipboard()
        } label: {
            Label("Copy Mac → iPad", systemImage: "arrow.down.doc")
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .disabled(!model.isConnected)

        Button {
            model.sendClipboardToMac()
        } label: {
            Label("Send iPad → Mac", systemImage: "arrow.up.doc")
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .disabled(!model.isConnected)
    }

    @ViewBuilder
    private var fileTransferButtons: some View {
        if let received = model.lastReceivedFile {
            ShareLink(item: received) {
                Label("Share Received", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
            }
            .buttonStyle(.bordered)
        }
        Button {
            showingFileImporter = true
        } label: {
            Label("Send File", systemImage: "paperplane.fill")
                .frame(maxWidth: horizontalSizeClass == .compact ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .disabled(!model.isConnected || model.isFileTransferring)
    }

    private var streamingView: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    // This is the only video layer used by the viewer and
                    // Picture in Picture. Keeping it inside the same
                    // scale/offset container as the input surface prevents
                    // zoom and letterbox transforms from drifting apart.
                    VideoDisplaySurface(controller: model.videoDisplay)
                        .ignoresSafeArea()
                        .opacity(model.frame == nil ? 1 : 0.01)
                        .allowsHitTesting(false)

                    if let frame = model.frame {
                        Image(uiImage: frame)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .ignoresSafeArea()
                            .accessibilityHidden(true)
                    }

                    if showVirtualCursor {
                        RemoteCursorOverlay(
                            normalizedPosition: model.remotePointer,
                            contentAspectRatio: model.streamAspectRatio,
                            isPressed: model.pointerIsPressed,
                            showClickIndicator: showClickFeedback && model.showClickIndicator
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .scaleEffect(viewerScale)
                .offset(viewerOffset)
                .clipped()

                RemoteInputSurface(
                    contentAspectRatio: model.streamAspectRatio,
                    zoomScale: viewerScale,
                    zoomOffset: viewerOffset,
                    pointerButtonMapping: pointerButtonMapping,
                    calibrateNextPointerClick: isCalibratingPointerButtons,
                    showsSoftwareKeyboard: showsSoftwareKeyboard,
                    showsMagicKeyboardPointer: showMagicKeyboardPointer,
                    onInput: model.sendInput,
                    onPointerCalibration: { mapping in
                        setPointerButtonMapping(mapping)
                    },
                    onZoom: { factor, anchor in
                        adjustViewerZoom(factor: factor, anchor: anchor, size: geometry.size)
                    },
                    onViewportPan: { delta in
                        panViewer(by: delta, size: geometry.size)
                    }
                )
                .ignoresSafeArea()

            VStack {
                if showTopStatusBar { streamTopStatusBar }

                if isCalibratingPointerButtons {
                    Label("Click the physical LEFT mouse or trackpad button once", systemImage: "cursorarrow.click")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Pointer calibration. Click the physical left button once.")
                }

                Spacer()

                if showBottomHint {
                    Text(model.remoteInputUnavailable
                         ? "The Mac is not accepting remote input yet • enable Accessibility on the Mac"
                         : model.remoteInputAuthorized
                         ? "One finger moves • tap clicks • hold then drag • two fingers scroll or pinch to zoom"
                            : "On the Mac: SidecarBridge → Enable Remote Input → allow Accessibility")
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                        .accessibilityLabel(model.remoteInputUnavailable
                            ? "The Mac is not accepting remote input yet. Enable SidecarBridge under macOS Privacy & Security → Accessibility."
                            : model.remoteInputAuthorized
                                ? "Remote input help: move one finger for the cursor, tap to click, hold then move to drag, or use two fingers to scroll."
                                : "Remote input requires Accessibility permission on the Mac.")
                }
            }

                streamingControlDrawer(availableSize: geometry.size)
            }
            // The captured frame, video layer, and UIKit input surface now
            // share this full-screen coordinate space. Without it,
            // GeometryReader can report the safe-area size while the viewer
            // extends under the status/home areas, producing a stable
            // click/pointer offset on iPad.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private var streamTopStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                streamIdentity
                Spacer()
                streamStatusActions
            }
            VStack(alignment: .leading, spacing: 10) {
                streamIdentity
                streamStatusActions
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding()
    }

    private var streamIdentity: some View {
        HStack(spacing: 9) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("SidecarBridge").font(.caption.bold())
                Label(streamQualityText, systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }

    private var streamStatusActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                streamStatusItems
            }
            VStack(alignment: .leading, spacing: 8) {
                streamStatusItems
            }
        }
    }

    @ViewBuilder
    private var streamStatusItems: some View {
        if let latency = model.connectionLatencyMS {
            Label("\(latency) ms", systemImage: "waveform.path.ecg")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .accessibilityLabel("Connection latency \(latency) milliseconds")
        }
        Label(inputStatusText, systemImage: inputStatusIcon)
            .font(.caption.bold())
            .foregroundStyle(model.remoteInputAuthorized && model.lastInputAccepted ? .cyan : .orange)
        Button("Stop") { model.stopStreaming() }
            .buttonStyle(.bordered)
    }

    private func streamingControlDrawer(availableSize: CGSize) -> some View {
        let drawerWidth = min(300, max(248, availableSize.width - 36))
        let drawerHeight = min(720, max(260, availableSize.height - 16))

        return HStack(spacing: 0) {
            Button {
                setControlDrawer(open: !controlDrawerOpen)
            } label: {
                Image(systemName: controlDrawerOpen ? "chevron.right" : "chevron.left")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 76)
                    .background(.cyan.gradient, in: UnevenRoundedRectangle(
                        topLeadingRadius: 13,
                        bottomLeadingRadius: 13
                    ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controlDrawerOpen ? "Close viewer controls" : "Open viewer controls")
            .accessibilityHint("Shows zoom, file transfer, background viewing, click, and display options.")

            if controlDrawerOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Viewer controls", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        Spacer()
                        Text("\(model.streamFPS) FPS")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Display zoom", systemImage: "magnifyingglass")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.78))
                            Spacer()
                            Text("\(Int((viewerScale * 100).rounded()))%")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.cyan)
                        }
                        HStack(spacing: 8) {
                            Button { zoomViewer(by: 0.8, size: availableSize) } label: { Image(systemName: "minus.magnifyingglass") }
                                .accessibilityLabel("Zoom out")
                            Button("Reset") { resetViewerZoom() }
                                .frame(maxWidth: .infinity)
                            Button { zoomViewer(by: 1.25, size: availableSize) } label: { Image(systemName: "plus.magnifyingglass") }
                                .accessibilityLabel("Zoom in")
                        }
                        .buttonStyle(.bordered)
                        Text("Pinch with two fingers to zoom. Drag with three fingers to pan; two-finger swipes still scroll the Mac.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("File transfer", systemImage: "arrow.left.arrow.right.square")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.78))
                        if let transfer = model.fileTransferSnapshot {
                            Text("\(transfer.message): \(transfer.fileName)")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: transfer.progress)
                                .tint(.cyan)
                                .accessibilityValue("\(Int(transfer.progress * 100)) percent")
                        }
                        Button {
                            showingFileImporter = true
                        } label: {
                            Label("Send File to Mac", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(model.isFileTransferring)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Clipboard", systemImage: "doc.on.clipboard")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.78))
                        HStack(spacing: 8) {
                            Button { model.requestMacClipboard() } label: {
                                Label("Mac → iPad", systemImage: "arrow.down.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { model.sendClipboardToMac() } label: {
                                Label("iPad → Mac", systemImage: "arrow.up.doc")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                        .disabled(!model.isConnected)
                        Text(model.clipboardTransferStatus)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label("Background viewer", systemImage: "pip")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.78))
                            Spacer()
                            Text(model.isPictureInPictureActive ? "ACTIVE" : model.keepRunningInBackground ? "AUTO" : "OFF")
                                .font(.caption2.bold())
                                .foregroundStyle(model.isPictureInPictureActive ? .green : .cyan)
                        }

                        Toggle(
                            isOn: Binding(
                                get: { model.keepRunningInBackground },
                                set: model.setKeepRunningInBackground
                            )
                        ) {
                            Text("Start PiP when switching apps")
                        }

                        if model.isPictureInPictureActive {
                            Button {
                                model.togglePictureInPicture()
                            } label: {
                                Label("Stop Picture in Picture", systemImage: "pip.exit")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        } else {
                            Button {
                                model.togglePictureInPicture()
                            } label: {
                                Label("Start PiP Now", systemImage: "pip.enter")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(!model.isStreaming || !model.pictureInPictureSupported)
                        }

                        Text(model.backgroundViewerDetail)
                            .font(.caption2)
                            .foregroundStyle(
                                model.isPictureInPictureActive || model.isPictureInPicturePossible
                                    ? Color.white.opacity(0.78)
                                    : model.pictureInPictureSupported ? Color.cyan : Color.orange
                            )
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Keyboard", systemImage: "keyboard")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.78))

                        Button {
                            showsSoftwareKeyboard.toggle()
                            if showsSoftwareKeyboard {
                                setControlDrawer(open: false)
                            }
                        } label: {
                            Label(
                                showsSoftwareKeyboard ? "Hide On-Screen Keyboard" : "Show On-Screen Keyboard",
                                systemImage: showsSoftwareKeyboard
                                    ? "keyboard.chevron.compact.down"
                                    : "keyboard.chevron.compact.up"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(showsSoftwareKeyboard ? .orange : .cyan)

                        Text("The software keyboard stays hidden until you select it here. Magic Keyboard and other hardware keyboards keep working.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("External pointer mapping", systemImage: "computermouse")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.78))

                        Picker("External pointer mapping", selection: Binding(
                            get: { pointerButtonMapping },
                            set: setPointerButtonMapping
                        )) {
                            Text("System").tag(RemotePointerButtonMapping.system)
                            Text("Swapped").tag(RemotePointerButtonMapping.swapped)
                        }
                        .pickerStyle(.segmented)

                        Button {
                            if isCalibratingPointerButtons {
                                isCalibratingPointerButtons = false
                            } else {
                                isCalibratingPointerButtons = true
                                setControlDrawer(open: false)
                            }
                        } label: {
                            Label(
                                isCalibratingPointerButtons ? "Cancel Left-Click Calibration" : "Calibrate Physical Left Click",
                                systemImage: isCalibratingPointerButtons ? "xmark.circle" : "scope"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Text(pointerMappingDetail)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.78))

                        Text("If other apps are also reversed: iPad Settings → General → Trackpad & Mouse → Secondary Click → Right.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Trackpad clicks", systemImage: "cursorarrow.click")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.78))

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                trackpadClickButtons
                            }
                            VStack(spacing: 8) {
                                trackpadClickButtons
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    streamingDisplayOptions

                    Divider()

                    Button {
                        selectedTab = .settings
                    } label: {
                        Label("More controls in Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Label(inputStatusText, systemImage: inputStatusIcon)
                        .font(.caption.bold())
                        .foregroundStyle(model.remoteInputAuthorized ? .cyan : .orange)

                    Button(role: .destructive) {
                        model.stopStreaming()
                    } label: {
                        Label("Stop stream", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .frame(width: drawerWidth)
                .background(.ultraThinMaterial)
                .overlay(alignment: .leading) { Divider() }
            }
        }
        }
        .frame(height: drawerHeight)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18
        ))
        .shadow(color: .black.opacity(0.35), radius: 20, x: -6)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.width < -35 {
                        setControlDrawer(open: true)
                    } else if value.translation.width > 35 {
                        setControlDrawer(open: false)
                    }
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var trackpadClickButtons: some View {
        TrackpadClickButton(
            title: "Left",
            systemImage: "cursorarrow.click",
            tint: .cyan,
            action: model.sendLeftClick
        )
        TrackpadClickButton(
            title: "Double",
            systemImage: "square.on.square",
            tint: .indigo,
            action: model.sendDoubleClick
        )
        TrackpadClickButton(
            title: "Right",
            systemImage: "contextualmenu.and.cursorarrow",
            tint: .orange,
            action: model.sendRightClick
        )
    }

    private var streamingDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Display options", systemImage: "slider.horizontal.2.square")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.78))

            Toggle(isOn: $showClickFeedback) {
                Label("Click ripple", systemImage: "circle.circle")
            }
            Toggle(isOn: $showMagicKeyboardPointer) {
                Label("Show iPad cursor", systemImage: "cursorarrow")
            }
            .onChange(of: showMagicKeyboardPointer) { _, value in
                UserDefaults.standard.set(value, forKey: "showMagicKeyboardPointer")
            }
            Toggle(isOn: $showTopStatusBar) {
                Label("Top status bar", systemImage: "rectangle.topthird.inset.filled")
            }
            Toggle(isOn: $showBottomHint) {
                Label("Bottom help", systemImage: "text.bubble")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private struct TrackpadClickButton: View {
        let title: String
        let systemImage: String
        let tint: Color
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.body.bold())
                    Text(title)
                        .font(.caption2.bold())
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .accessibilityLabel("\(title) click")
        }
    }

    private var supportsSystemSidecar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private func setControlDrawer(open: Bool) {
        if reduceMotion {
            controlDrawerOpen = open
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                controlDrawerOpen = open
            }
        }
    }

    private var inputStatusText: String {
        if model.remoteInputUnavailable { return "VIEWER ONLY" }
        guard model.remoteInputAuthorized, model.lastInputAccepted else { return "MAC PERMISSION REQUIRED" }
        guard let latency = model.controlLatencyMS else { return "TRACKPAD READY" }
        return "INPUT \(latency) MS"
    }

    private var pointerMappingDetail: String {
        switch pointerButtonMapping {
        case .system:
            return "System mapping: iPad primary is left; secondary is right."
        case .swapped:
            return "Swapped mapping: SidecarBridge converts iPad secondary into left click."
        }
    }

    private func setPointerButtonMapping(_ mapping: RemotePointerButtonMapping) {
        pointerButtonMapping = mapping
        isCalibratingPointerButtons = false
        UserDefaults.standard.set(mapping.rawValue, forKey: "pointerButtonMapping")
    }

    private func adjustViewerZoom(factor: CGFloat, anchor: CGPoint, size: CGSize) {
        let oldScale = viewerScale
        let newScale = min(max(oldScale * factor, 1), 4)
        guard abs(newScale - oldScale) > 0.001 else { return }
        if newScale <= 1.001 {
            viewerScale = 1
            viewerOffset = .zero
            return
        }

        let anchorPoint = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
        let centered = CGPoint(x: anchorPoint.x - size.width / 2, y: anchorPoint.y - size.height / 2)
        let ratio = newScale / oldScale
        let proposed = CGSize(
            width: centered.x - ratio * (centered.x - viewerOffset.width),
            height: centered.y - ratio * (centered.y - viewerOffset.height)
        )
        viewerScale = newScale
        viewerOffset = clampedViewerOffset(proposed, scale: newScale, size: size)
    }

    private func panViewer(by delta: CGSize, size: CGSize) {
        guard viewerScale > 1 else { return }
        viewerOffset = clampedViewerOffset(
            CGSize(width: viewerOffset.width + delta.width, height: viewerOffset.height + delta.height),
            scale: viewerScale,
            size: size
        )
    }

    private func zoomViewer(by factor: CGFloat, size: CGSize) {
        let newScale = min(max(viewerScale * factor, 1), 4)
        if newScale <= 1.001 {
            resetViewerZoom()
        } else {
            let ratio = newScale / viewerScale
            viewerScale = newScale
            viewerOffset = clampedViewerOffset(
                CGSize(width: viewerOffset.width * ratio, height: viewerOffset.height * ratio),
                scale: newScale,
                size: size
            )
        }
    }

    private func resetViewerZoom() {
        viewerScale = 1
        viewerOffset = .zero
    }

    private func clampedViewerOffset(_ offset: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        // Only the letterboxed Mac content moves when zoomed. Using the full
        // iPad bounds here lets the image drift farther than the input
        // normalization rectangle, which presents as a cursor/click offset
        // after a pinch followed by a three-finger pan.
        let content = RemoteDisplayGeometry.contentRect(
            in: size,
            aspectRatio: model.streamAspectRatio
        )
        let maximumX = max(0, content.width * (scale - 1) / 2)
        let maximumY = max(0, content.height * (scale - 1) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    private var streamQualityText: String {
        guard model.frame == nil else { return "Encrypted HiDPI stream" }
        guard model.streamFPS > 0 else { return "Hardware H.264 HiDPI" }
        return "Hardware H.264 HiDPI • \(model.streamFPS) FPS"
    }

    private var inputStatusIcon: String {
        if model.remoteInputUnavailable { return "eye" }
        return model.remoteInputAuthorized && model.lastInputAccepted
            ? "cursorarrow.motionlines"
            : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if model.localNetworkPermissionNeeded { return .orange }
        if model.isConnected { return .green }
        return .cyan
    }

    private var statusIcon: String {
        if model.localNetworkPermissionNeeded { return "exclamationmark.shield" }
        if model.isConnected { return "checkmark.circle" }
        return "ipad.and.arrow.forward"
    }

    private var localNetworkDetail: String {
        switch model.localNetworkAccess {
        case .checking: return "Checking Wi-Fi and AWDL access"
        case .granted: return "Direct discovery permission passed"
        case .denied: return "Open Settings to allow discovery"
        case .unavailable(let reason): return "Unavailable: \(reason)"
        }
    }

    private var localNetworkBadge: String {
        switch model.localNetworkAccess {
        case .checking: return "CHECKING"
        case .granted: return "PASSED"
        case .denied: return "ACTION"
        case .unavailable: return "WAITING"
        }
    }

    private var localNetworkTint: Color {
        switch model.localNetworkAccess {
        case .granted: return .green
        case .denied: return .orange
        case .checking, .unavailable: return .cyan
        }
    }

    private var searchElapsedText: String {
        let minutes = model.discoveryElapsedSeconds / 60
        let seconds = model.discoveryElapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var sessionSummaryTitle: String {
        if model.isConnected {
            return model.isStreaming ? "Mac screen" : "App stream paused"
        }
        if model.isConnecting { return "Connecting to selected Mac…" }
        if model.selectedMacName != nil { return "Ready to connect to selected Mac" }
        return model.discoveredMacs.isEmpty ? "Looking for your Mac…" : "Mac ready to connect"
    }

    private var sessionSummaryDetail: String {
        if model.isConnected {
            return model.isStreaming ? model.detail : "Choose App Stream to continue controlling this Mac."
        }
        if model.isConnecting { return "Establishing the encrypted local session. This can use the direct or nearby path." }
        return model.selectedMacName.map { "Use the Connect button on the \($0) device card to start the encrypted session." }
            ?? (model.discoveredMacs.isEmpty
                ? "Keep SidecarBridge open on the Mac while discovery runs."
                : "Select a Mac device card, then tap Connect when you are ready.")
    }

    private var discoveryDetail: String {
        if model.localNetworkPermissionNeeded {
            return "SidecarBridge cannot see devices until Local Network access is enabled."
        }
        if !model.discoveredMacs.isEmpty {
            return "Choose a Mac below and tap Connect when you want to start a session."
        }
        if model.discoveryElapsedSeconds < 2 {
            return "Checking the fastest direct path on your local network."
        }
        return "Searching direct Wi-Fi/AWDL and nearby P2P at the same time."
    }

    private var discoveryRecoveryText: String {
        if model.localNetworkPermissionNeeded {
            return "Enable Local Network for SidecarBridge, then return here; discovery restarts automatically."
        }
        return "Keep SidecarBridge open on the Mac. Confirm both devices use the same Wi-Fi, Bluetooth is enabled, and the Mac firewall allows local connections."
    }
}

private struct MacDiscoveryPulse: View {
    let tint: Color
    let reduceMotion: Bool

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            pulse(phase: 0.35)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                pulse(phase: phase)
            }
        }
    }

    private func pulse(phase: Double) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.45 * (1 - phase)), lineWidth: 2)
                .scaleEffect(0.72 + phase * 0.42)
            Circle()
                .fill(tint.opacity(0.12))
            Image(systemName: "desktopcomputer.and.macbook")
                .font(.title2.bold())
                .foregroundStyle(tint)
        }
    }
}

private struct DiscoveryPathTile: View {
    let icon: String
    let title: String
    let detail: String
    let state: String
    let tint: Color
    let isActive: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                pathIcon
                pathDescription
                Spacer(minLength: 5)
                pathState
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    pathIcon
                    pathDescription
                }
                pathState
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(tint.opacity(isActive ? 0.28 : 0.1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state)")
        .accessibilityValue(detail)
    }

    private var pathIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(tint.opacity(0.14))
            if isActive {
                ProgressView().tint(tint)
            } else {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private var pathDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.bold())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pathState: some View {
        Text(state)
            .font(.caption2.bold())
            .foregroundStyle(tint)
    }
}

private struct RemoteCursorOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let normalizedPosition: CGPoint?
    let contentAspectRatio: CGFloat
    let isPressed: Bool
    let showClickIndicator: Bool

    var body: some View {
        GeometryReader { geometry in
            if let normalizedPosition {
                let rect = contentRect(in: geometry.size)
                let point = CGPoint(
                    x: rect.minX + normalizedPosition.x * rect.width,
                    y: rect.minY + normalizedPosition.y * rect.height
                )

                ZStack {
                    if showClickIndicator || isPressed {
                        Circle()
                            .stroke(isPressed ? Color.cyan : Color.white, lineWidth: 3)
                            .background(Circle().fill(Color.cyan.opacity(isPressed ? 0.22 : 0.1)))
                            .frame(width: isPressed ? 34 : 46, height: isPressed ? 34 : 46)
                            .position(point)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Image(systemName: "cursorarrow")
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 1, y: 2)
                        .overlay {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 29, weight: .black))
                                .foregroundStyle(.clear)
                                .shadow(color: .cyan.opacity(isPressed ? 0.9 : 0.45), radius: isPressed ? 8 : 4)
                        }
                        .position(x: point.x + 10, y: point.y + 13)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showClickIndicator)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
            }
        }
    }

    private func contentRect(in size: CGSize) -> CGRect {
        RemoteDisplayGeometry.contentRect(in: size, aspectRatio: contentAspectRatio)
    }
}

private struct PadSystemInformationSheet: View {
    @ObservedObject var model: PadConnectionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    informationSection(
                        title: "This \(model.localSystemInformation.platform)",
                        icon: "ipad.and.iphone",
                        information: model.localSystemInformation,
                        tint: .cyan
                    )
                    informationSection(
                        title: "Connected Mac",
                        icon: "desktopcomputer",
                        information: model.remoteSystemInformation,
                        tint: .purple
                    )
                    connectionSection

                    Text("The copied report excludes pairing codes, credentials, device IDs, IP addresses, and file paths.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("System Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") { model.refreshSystemInformation() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.copyDiagnosticReport()
                } label: {
                    Label("Copy Diagnostic Report", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .controlSize(.large)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func informationSection(
        title: String,
        icon: String,
        information: SystemInformation?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            if let information {
                ForEach(Array(information.summaryRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(row.name).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    if row != information.summaryRows.last {
                        Divider()
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Mac Snapshot",
                    systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                    description: Text("Connect securely, then tap Refresh.")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Live connection", systemImage: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(.green)
            diagnosticRow("Transport", model.connectionTransport)
            Divider()
            diagnosticRow("Link", model.connectionHealthDetail)
            Divider()
            diagnosticRow(
                "Latency",
                model.connectionLatencyMS.map { "\($0) ms" } ?? "Not measured"
            )
            Divider()
            diagnosticRow("Stream", model.streamDimensions)
            Divider()
            diagnosticRow(
                "Displayed frame rate",
                model.streamFPS > 0 ? "\(model.streamFPS) FPS" : "Not measured"
            )
            Divider()
            diagnosticRow(
                "Input latency",
                model.controlLatencyMS.map { "\($0) ms" } ?? "Not measured"
            )
            Divider()
            diagnosticRow("Background viewer", model.backgroundViewerStatus)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func diagnosticRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct PadSettingsPanel: View {
    @ObservedObject var model: PadConnectionModel
    @Binding var showVirtualCursor: Bool
    @Binding var showClickFeedback: Bool
    @Binding var showTopStatusBar: Bool
    @Binding var showBottomHint: Bool
    @Binding var showsSoftwareKeyboard: Bool
    @Binding var pointerButtonMapping: RemotePointerButtonMapping
    @Binding var isCalibratingPointerButtons: Bool
    @Binding var showingFileImporter: Bool
    let onOpenRemoteControl: () -> Void
    // Android-style developer options stay hidden until the version row is
    // tapped seven times, then persist so the enabled state is reflected when
    // Settings is reopened.
    @AppStorage("sidecarbridge.developerModeEnabled") private var developerModeEnabled = false
    @State private var versionTapCount = 0
    @State private var versionLastTappedAt = Date.distantPast
    @State private var developerUnlockHint: String?
    @State private var showingSystemInformation = false
    @State private var showingForgetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    settingsHeroCard
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                            .frame(width: 42, height: 42)
                            .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.selectedMacName ?? "No Mac selected")
                                .font(.headline)
                            Text(model.isConnected ? model.connectionTransport : "Choose a Mac from the home screen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        onOpenRemoteControl()
                        if !model.isConnected {
                            model.connectSelectedMac()
                        } else if model.preferTrackpadControl || !supportsSystemSidecar {
                            model.requestFallback()
                        } else {
                            model.requestSystemSidecar()
                        }
                    } label: {
                        Label(
                            model.isConnected
                                ? (model.preferTrackpadControl || !supportsSystemSidecar ? "Open In-App Display" : "Open System Sidecar")
                                : "Connect to selected Mac",
                            systemImage: model.isConnected ? "play.fill" : "arrow.right.circle.fill"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(model.selectedMacName == nil || model.isConnecting)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Connection settings stay separate from the remote viewer, so you can reach them before and during a session.")
                }

                Section("Display mode") {
                    settingsModeButton(
                        title: "In-App Display",
                        detail: "Keep the Mac screen, keyboard, and trackpad inside SidecarBridge.",
                        icon: "cursorarrow.motionlines",
                        tint: .cyan,
                        selected: model.preferTrackpadControl
                    ) {
                        model.setPreferTrackpadControl(true)
                    }

                    if supportsSystemSidecar {
                        settingsModeButton(
                            title: "System Sidecar",
                            detail: "Open Apple's separate display session.",
                            icon: "rectangle.connected.to.line.below",
                            tint: .purple,
                            selected: !model.preferTrackpadControl
                        ) {
                            model.setPreferTrackpadControl(false)
                        }
                    }
                }

                transfersSection

                Section("Viewer") {
                    Toggle(isOn: $showClickFeedback) {
                        Label("Click feedback", systemImage: "circle.circle")
                    }
                    Toggle(isOn: $showTopStatusBar) {
                        Label("Top status bar", systemImage: "rectangle.topthird.inset.filled")
                    }
                    Toggle(isOn: $showBottomHint) {
                        Label("Bottom help", systemImage: "text.bubble")
                    }
                }

                Section("Keyboard & pointer") {
                    Button {
                        showsSoftwareKeyboard.toggle()
                        if showsSoftwareKeyboard { onOpenRemoteControl() }
                    } label: {
                        Label(
                            showsSoftwareKeyboard ? "Hide On-Screen Keyboard" : "Show On-Screen Keyboard",
                            systemImage: showsSoftwareKeyboard ? "keyboard.chevron.compact.down" : "keyboard.chevron.compact.up"
                        )
                    }

                    pointerMappingPicker

                    Button {
                        isCalibratingPointerButtons = true
                        onOpenRemoteControl()
                    } label: {
                        Label("Calibrate left click", systemImage: "scope")
                    }
                    Text("Use the physical left button once if another remote-control app reports the opposite button mapping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.keepRunningInBackground },
                        set: model.setKeepRunningInBackground
                    )) {
                        Label("Resume in Picture in Picture", systemImage: "pip")
                    }
                    Button {
                        model.togglePictureInPicture()
                    } label: {
                        Label(
                            model.isPictureInPictureActive ? "Stop Picture in Picture" : "Start Picture in Picture",
                            systemImage: model.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                        )
                    }
                    .disabled(
                        !model.isPictureInPictureActive
                            && (!model.isStreaming || !model.pictureInPictureSupported)
                    )
                    Text(model.backgroundViewerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Background viewer")
                } footer: {
                    Text("Picture in Picture can keep the Mac screen visible. Keyboard and trackpad input resumes when SidecarBridge is foreground; if PiP is unavailable, iPadOS may suspend the app and SidecarBridge restores the encrypted link when you return.")
                }

                Section {
                    Button(role: .destructive) {
                        showingForgetConfirmation = true
                    } label: {
                        Label("Forget trusted Macs", systemImage: "trash")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Pairing credentials remain in the iPad Keychain until you choose to forget them.")
                }

                Section("About") {
                    // Android-style developer unlock: tap the version row
                    // seven times in quick succession. A Button is used
                    // instead of a multi-tap gesture so the action remains
                    // reliable inside a SwiftUI Form on iPadOS.
                    Button(action: registerVersionTap) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label("Version", systemImage: developerModeEnabled ? "checkmark.shield.fill" : "info.circle")
                                Spacer()
                                Text(appVersion)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            if developerModeEnabled {
                                Text("Developer options enabled")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else if versionTapCount > 0 {
                                Text("Tap \(max(1, 7 - versionTapCount)) more times to unlock developer options")
                                    .font(.caption)
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if let developerUnlockHint {
                        Label(developerUnlockHint, systemImage: developerModeEnabled ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(developerModeEnabled ? .green : .secondary)
                    }
                }

                if developerModeEnabled {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Developer mode is on")
                                    .font(.headline)
                                Text("Diagnostics are visible below and stay enabled until you hide them.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            showingSystemInformation = true
                        } label: {
                            Label("System information", systemImage: "info.circle")
                        }
                        Button {
                            model.refreshSystemInformation()
                        } label: {
                            Label("Refresh connection details", systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.copyDiagnosticReport()
                        } label: {
                            Label("Copy diagnostic report", systemImage: "doc.on.doc")
                        }
                        DisclosureGroup("Connection debug details") {
                            Text(model.diagnosticReport)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(role: .destructive) {
                            developerModeEnabled = false
                            developerUnlockHint = "Developer options hidden."
                        } label: {
                            Label("Hide developer options", systemImage: "eye.slash")
                        }
                    } header: {
                        Text("Developer")
                    } footer: {
                        Text("Developer diagnostics can contain device and connection details. Share them only with people you trust.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(.cyan)
        .sheet(isPresented: $showingSystemInformation) {
            PadSystemInformationSheet(model: model)
        }
        .confirmationDialog(
            "Forget every trusted Mac?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Trusted Macs", role: .destructive) {
                model.forgetTrustedMacs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need the current pairing code the next time you connect.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    private var settingsHeroCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 13) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .cyan.opacity(0.22), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Control Center")
                        .font(.title3.bold())
                    Text("Tune the viewer, input, transfers, and background behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(model.isConnected ? "CONNECTED" : "OFFLINE")
                    .font(.caption2.bold())
                    .foregroundStyle(model.isConnected ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background((model.isConnected ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
            }

            HStack(spacing: 8) {
                settingsStatusPill(
                    title: "Remote input",
                    value: model.remoteInputAuthorized ? "Ready" : "Needs Mac access",
                    icon: "cursorarrow.motionlines",
                    tint: model.remoteInputAuthorized ? .green : .orange
                )
                settingsStatusPill(
                    title: "Background",
                    value: model.keepRunningInBackground ? "PiP enabled" : "Off",
                    icon: "pip",
                    tint: model.keepRunningInBackground ? .cyan : .secondary
                )
            }
        }
        .padding(17)
        .background(
            LinearGradient(
                colors: [.cyan.opacity(0.15), .purple.opacity(0.10), .white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.cyan.opacity(0.22)))
    }

    private func settingsStatusPill(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func registerVersionTap() {
        let now = Date()
        if now.timeIntervalSince(versionLastTappedAt) > 2 {
            versionTapCount = 1
        } else {
            versionTapCount += 1
        }
        versionLastTappedAt = now
        if versionTapCount >= 7 {
            versionTapCount = 0
            developerModeEnabled = true
            developerUnlockHint = "Developer options unlocked."
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else if !developerModeEnabled {
            developerUnlockHint = "Developer unlock: \(max(1, 7 - versionTapCount)) taps remaining."
        }
    }

    private var transfersSection: some View {
        Section {
            Button {
                showingFileImporter = true
            } label: {
                Label("Send file to Mac", systemImage: "paperplane.fill")
            }
            .disabled(!model.isConnected)

            if let received = model.lastReceivedFile {
                ShareLink(item: received) {
                    Label("Share received file", systemImage: "square.and.arrow.up")
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.requestMacClipboard()
                } label: {
                    Label("Mac → iPad", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button {
                    model.sendClipboardToMac()
                } label: {
                    Label("iPad → Mac", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(!model.isConnected)

            if let transfer = model.fileTransferSnapshot {
                Text("\(transfer.message): \(transfer.fileName)")
                    .font(.caption)
                ProgressView(value: transfer.progress)
                    .tint(.cyan)
            } else if let error = model.fileTransferError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(model.clipboardTransferStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Transfers")
        } footer: {
            Text("Files and clipboard text use the encrypted connection and are transferred only when you tap an action.")
        }
    }

    private var pointerMappingPicker: some View {
        Picker("External pointer mapping", selection: $pointerButtonMapping) {
            Text("System").tag(RemotePointerButtonMapping.system)
            Text("Swapped").tag(RemotePointerButtonMapping.swapped)
        }
        .onChange(of: pointerButtonMapping) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: "pointerButtonMapping")
        }
    }

    private var supportsSystemSidecar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private func settingsModeButton(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? tint : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PadPermissionTile: View {
    let icon: String
    let title: String
    let detail: String
    let state: String
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 13) {
                permissionIcon
                permissionDescription
                Spacer(minLength: 8)
                permissionState
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 13) {
                    permissionIcon
                    permissionDescription
                }
                permissionState
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(state)")
        .accessibilityValue(detail)
    }

    private var permissionIcon: some View {
        Image(systemName: icon)
            .font(.title3.bold())
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    private var permissionDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionState: some View {
        Text(state)
            .font(.caption2.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct PadModeCard: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let icon: String
    let title: String
    let description: String
    let badge: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: icon)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 50, height: 50)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(title).font(.title3.bold())
                            modeBadge
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.title3.bold())
                            modeBadge
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Image(systemName: isSelected
                    ? (differentiateWithoutColor ? "checkmark.square.fill" : "checkmark.circle.fill")
                    : (differentiateWithoutColor ? "square" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isSelected ? tint : .white.opacity(0.22))
            }
            .padding(17)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: isSelected ? [tint.opacity(0.15), .white.opacity(0.04)] : [.white.opacity(0.045), .white.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 19, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(isSelected ? tint.opacity(0.55) : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(description)
    }

    private var modeBadge: some View {
        Text(badge)
            .font(.caption.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct RequirementPill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.76))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.045), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
