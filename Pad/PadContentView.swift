import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PadContentView: View {
    @ObservedObject var model: PadConnectionModel
    @State private var controlDrawerOpen = false
    @State private var showingFileImporter = false
    @State private var viewerScale: CGFloat = 1
    @State private var viewerOffset: CGSize = .zero
    @State private var showVirtualCursor: Bool = {
        UserDefaults.standard.object(forKey: "showVirtualCursor") as? Bool ?? true
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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.018, green: 0.025, blue: 0.09), Color(red: 0.06, green: 0.035, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if model.isStreaming {
                streamingView
            } else {
                dashboard
            }
        }
        .preferredColorScheme(.dark)
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.sendFile(at: url) }
            case .failure(let error):
                model.fileTransferError = error.localizedDescription
            }
        }
    }

    private var dashboard: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if model.isConnected {
                        connectionCard
                    } else {
                        discoveryCard
                    }
                    permissionStrip
                    modeChooser
                    actionBar
                    fileTransferCard
                    requirementStrip
                }
                .frame(maxWidth: 920)
                .frame(minHeight: geometry.size.height - 48)
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .blue.opacity(0.35), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text("SidecarBridge")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("A trackpad-capable window into your Mac")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Label("LOCAL + ENCRYPTED", systemImage: "lock.fill")
                .font(.caption2.bold())
                .tracking(1)
                .foregroundStyle(.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.cyan.opacity(0.1), in: Capsule())
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(statusColor.opacity(0.14))
                Image(systemName: statusIcon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.status)
                    .font(.title2.bold())
                Text(model.detail)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.56))
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(model.isConnected ? "MAC CONNECTED" : "SEARCHING")
                        .font(.caption2.bold())
                        .tracking(0.9)
                }
                .foregroundStyle(statusColor)
                Text(model.preferTrackpadControl ? "In-App Display mode" : "System Sidecar mode")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                MacDiscoveryPulse(tint: model.localNetworkPermissionNeeded ? .orange : .cyan)
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localNetworkPermissionNeeded ? "Discovery needs permission" : "Looking for your Mac")
                        .font(.title2.bold())
                    Text(discoveryDetail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 7) {
                    Text("ATTEMPT \(model.discoveryAttempt)")
                        .font(.caption2.bold())
                        .tracking(0.9)
                        .foregroundStyle(model.localNetworkPermissionNeeded ? .orange : .cyan)
                    Text(searchElapsedText)
                        .font(.system(.body, design: .monospaced).bold())
                    Button {
                        model.retry()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().overlay(.white.opacity(0.08))

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
        .animation(.easeInOut(duration: 0.25), value: model.isDiscoveryTakingLonger)
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
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if let issue = model.lastDiscoveryIssue, !model.localNetworkPermissionNeeded {
                    Text(issue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
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
            HStack {
                Text("Choose how to use your iPad")
                    .font(.headline)
                Spacer()
                    Text("IN-APP DISPLAY RECOMMENDED")
                    .font(.caption2.bold())
                    .tracking(0.8)
                    .foregroundStyle(.cyan)
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

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                model.retry()
            } label: {
                Label("Search Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                if model.preferTrackpadControl {
                    model.requestFallback()
                } else {
                    model.requestSystemSidecar()
                }
            } label: {
                Label(
                    model.preferTrackpadControl ? "Start In-App Display" : "Open System Sidecar",
                    systemImage: model.preferTrackpadControl ? "play.fill" : "rectangle.connected.to.line.below"
                )
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
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    private var requirementStrip: some View {
        HStack(spacing: 10) {
            RequirementPill(icon: "wifi", text: "Local link + AWDL")
            RequirementPill(icon: "lock.fill", text: "Encrypted link")
            RequirementPill(icon: "keyboard", text: "Magic Keyboard")
            RequirementPill(icon: "rectangle.and.hand.point.up.left", text: "Trackpad + touch")
            Spacer()
        }
        .padding(.top, 2)
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
                    Text("Transfer through the same encrypted local connection used by the display.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer(minLength: 10)
            if let received = model.lastReceivedFile {
                ShareLink(item: received) {
                    Label("Share Received", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            Button {
                showingFileImporter = true
            } label: {
                Label("Send File", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!model.isConnected || model.isFileTransferring)
        }
        .padding(17)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private var streamingView: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    if let frame = model.frame {
                        Image(uiImage: frame)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .ignoresSafeArea()
                    } else {
                        VideoDisplaySurface(controller: model.videoDisplay)
                            .ignoresSafeArea()
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
                    }
                }
                .scaleEffect(viewerScale)
                .offset(viewerOffset)
                .clipped()

                RemoteInputSurface(
                    contentAspectRatio: model.streamAspectRatio,
                    zoomScale: viewerScale,
                    zoomOffset: viewerOffset,
                    onInput: model.sendInput,
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

                Spacer()

                if showBottomHint {
                    Text(model.remoteInputAuthorized
                         ? "Two-finger scroll • pinch zoom • three-finger pan • left/right click"
                         : "On the Mac: SidecarBridge → Enable Remote Input → allow Accessibility")
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                }
            }

                streamingControlDrawer
            }
        }
    }

    private var streamTopStatusBar: some View {
        HStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("SidecarBridge").font(.caption.bold())
                Label(streamQualityText, systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(inputStatusText, systemImage: inputStatusIcon)
                .font(.caption2.bold())
                .tracking(0.7)
                .foregroundStyle(model.remoteInputAuthorized && model.lastInputAccepted ? .cyan : .orange)
            Button("Stop") { model.stopStreaming() }
                .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding()
    }

    private var streamingControlDrawer: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { controlDrawerOpen.toggle() }
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

            if controlDrawerOpen {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Viewer controls", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        Spacer()
                        Text("\(model.streamFPS) FPS")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Display zoom", systemImage: "magnifyingglass")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int((viewerScale * 100).rounded()))%")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.cyan)
                        }
                        HStack(spacing: 8) {
                            Button { zoomViewer(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                            Button("Reset") { resetViewerZoom() }
                                .frame(maxWidth: .infinity)
                            Button { zoomViewer(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        }
                        .buttonStyle(.bordered)
                        Text("Pinch with two fingers to zoom. Drag with three fingers to pan; two-finger swipes still scroll the Mac.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("File transfer", systemImage: "arrow.left.arrow.right.square")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        if let transfer = model.fileTransferSnapshot {
                            Text("\(transfer.message): \(transfer.fileName)")
                                .font(.caption2)
                                .lineLimit(1)
                            ProgressView(value: transfer.progress).tint(.cyan)
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

                    Button {
                        model.togglePictureInPicture()
                    } label: {
                        Label(
                            model.isPictureInPictureActive ? "Stop Picture in Picture" : "Keep Running in Background",
                            systemImage: model.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isPictureInPictureActive ? .orange : .cyan)
                    .disabled(!model.isPictureInPicturePossible && !model.isPictureInPictureActive)

                    Text(model.isPictureInPictureActive
                         ? "Background viewer is active. Pointer control resumes when you return."
                         : "Tap before switching apps to keep the live Mac screen connected.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Trackpad clicks", systemImage: "cursorarrow.click")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
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
                    }

                    Toggle(isOn: $showVirtualCursor) {
                        Label("Virtual cursor", systemImage: "cursorarrow")
                    }
                    Toggle(isOn: $showClickFeedback) {
                        Label("Click ripple", systemImage: "circle.circle")
                    }
                    .disabled(!showVirtualCursor)
                    Toggle(isOn: $showTopStatusBar) {
                        Label("Top status bar", systemImage: "rectangle.topthird.inset.filled")
                    }
                    Toggle(isOn: $showBottomHint) {
                        Label("Bottom help", systemImage: "text.bubble")
                    }

                    Divider()

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
                .padding(20)
                .frame(width: 310)
                .background(.ultraThinMaterial)
                .overlay(alignment: .leading) { Divider() }
            }
        }
        .frame(height: 760)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18
        ))
        .shadow(color: .black.opacity(0.35), radius: 20, x: -6)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.width < -35 {
                        withAnimation(.snappy(duration: 0.22)) { controlDrawerOpen = true }
                    } else if value.translation.width > 35 {
                        withAnimation(.snappy(duration: 0.22)) { controlDrawerOpen = false }
                    }
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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

    private var inputStatusText: String {
        guard model.remoteInputAuthorized, model.lastInputAccepted else { return "MAC PERMISSION REQUIRED" }
        guard let latency = model.controlLatencyMS else { return "TRACKPAD READY" }
        return "INPUT \(latency) MS"
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

    private func zoomViewer(by factor: CGFloat) {
        let newScale = min(max(viewerScale * factor, 1), 4)
        if newScale <= 1.001 {
            resetViewerZoom()
        } else {
            let ratio = newScale / viewerScale
            viewerScale = newScale
            viewerOffset = CGSize(width: viewerOffset.width * ratio, height: viewerOffset.height * ratio)
        }
    }

    private func resetViewerZoom() {
        viewerScale = 1
        viewerOffset = .zero
    }

    private func clampedViewerOffset(_ offset: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        let maximumX = max(0, size.width * (scale - 1) / 2)
        let maximumY = max(0, size.height * (scale - 1) / 2)
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
        model.remoteInputAuthorized && model.lastInputAccepted
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

    private var discoveryDetail: String {
        if model.localNetworkPermissionNeeded {
            return "SidecarBridge cannot see devices until Local Network access is enabled."
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.45 * (1 - phase)), lineWidth: 2)
                    .scaleEffect(0.72 + phase * 0.42)
                Circle()
                    .fill(tint.opacity(0.12))
                Image(systemName: "desktopcomputer.and.macbook")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(tint)
            }
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(tint.opacity(0.12))
                if isActive {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(2)
            }
            Spacer(minLength: 5)
            Text(state)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(tint.opacity(isActive ? 0.28 : 0.1)))
    }
}

private struct RemoteCursorOverlay: View {
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
                .animation(.easeOut(duration: 0.14), value: showClickIndicator)
                .animation(.easeOut(duration: 0.1), value: isPressed)
            }
        }
    }

    private func contentRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, contentAspectRatio > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let viewAspect = size.width / size.height
        if viewAspect > contentAspectRatio {
            let width = size.height * contentAspectRatio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = size.width / contentAspectRatio
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

private struct PadPermissionTile: View {
    let icon: String
    let title: String
    let detail: String
    let state: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(state)
                .font(.caption2.bold())
                .tracking(0.7)
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.11), in: Capsule())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
    }
}

private struct PadModeCard: View {
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
                    HStack {
                        Text(title).font(.title3.bold())
                        Text(badge)
                            .font(.caption2.bold())
                            .tracking(0.7)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.11), in: Capsule())
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.54))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
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
    }
}

private struct RequirementPill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.52))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white.opacity(0.045), in: Capsule())
    }
}
