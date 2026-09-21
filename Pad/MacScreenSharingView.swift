import SwiftUI
import Security

private enum ScreenSharingCredentials {
    static func query(_ address: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.sidecarbridge.vnc",
         kSecAttrAccount as String: address.lowercased()]
    }
    static func read(_ address: String) -> String? {
        var request = query(address)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    static func save(_ password: String, address: String) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query(address) as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        return SecItemAdd(query(address).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func forget(_ address: String) { SecItemDelete(query(address) as CFDictionary) }
}

@MainActor
final class MacScreenSharingModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "vnc.lastHost") ?? ""
    @Published var port = "5900"
    @Published var password = ""
    @Published var remember = true
    @Published var localNetworkConsent = false
    @Published private(set) var image: CGImage?
    @Published private(set) var status = "Ready to connect"
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var desktopName = "Mac Screen Sharing"
    private var session: MacScreenSharingSession?
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var input = RFBInput()
    private var width = 0
    private var height = 0
    private var address: String { "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port)" }

    func connect() {
        disconnect()
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("://"),
              let port = UInt16(port), port > 0 else {
            status = "Enter the Mac’s local IP address or hostname and a valid port."; return
        }
        guard localNetworkConsent else { status = "Confirm that you trust this local network before connecting."; return }
        let secret = password.isEmpty ? (ScreenSharingCredentials.read(address) ?? "") : password
        do { _ = try RFBProtocol.challengeResponse(Data(count: 16), password: secret) }
        catch { status = error.localizedDescription; return }
        let identity = generation
        let endpoint = address
        let shouldRemember = remember
        let connection = MacScreenSharingSession(host: host, port: port)
        session = connection
        busy = true; status = "Connecting to \(host)…"
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == identity, self.busy else { return }
            self.disconnect()
            self.status = "Connection timed out. Check the address, Screen Sharing, VNC password setting, and the Mac firewall."
        }
        task = Task { [weak self] in
            do {
                let (name, width, height) = try await connection.open(password: secret)
                guard let self, self.generation == identity, !Task.isCancelled else { return }
                self.desktopName = name.isEmpty ? host : name
                self.width = width; self.height = height
                self.status = "Authenticated — waiting for the Mac’s screen…"
                // Keep the connection deadline until the first frame arrives.
                let firstFrame = try await connection.nextFrame()
                guard self.generation == identity, !Task.isCancelled else { return }
                self.timeout?.cancel()
                self.width = firstFrame.width; self.height = firstFrame.height
                self.image = firstFrame; self.busy = false; self.connected = true
                UserDefaults.standard.set(host, forKey: "vnc.lastHost")
                self.password = ""
                if shouldRemember {
                    self.status = ScreenSharingCredentials.save(secret, address: endpoint)
                        ? "Connected • VNC • Local network" : "Connected • Could not save password in Keychain"
                } else {
                    ScreenSharingCredentials.forget(endpoint)
                    self.status = "Connected • VNC • Password not saved"
                }
                while !Task.isCancelled {
                    let frame = try await connection.nextFrame()
                    guard self.generation == identity else { return }
                    self.width = frame.width; self.height = frame.height
                    self.image = frame
                }
            } catch {
                guard let self, self.generation == identity, !Task.isCancelled else { return }
                self.disconnect()
                self.status = error.localizedDescription
            }
        }
    }
    func send(_ event: RemoteInputEvent) {
        guard connected, let session else { return }
        session.send(input.encode(event, width: width, height: height))
    }
    func disconnect() {
        if connected { send(.releaseButtons()) }
        generation = UUID()
        timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        session?.cancel(); session = nil
        image = nil; connected = false; busy = false
        input = RFBInput(); status = "Disconnected"
    }
    func background() {
        guard connected || busy else { return }
        disconnect()
        status = "Paused while in the background. Tap Connect to request a fresh Mac screen."
    }
    func forgetPassword() {
        ScreenSharingCredentials.forget(address)
        password = ""; status = "Saved VNC password removed for this address."
    }
}

struct MacScreenSharingView: View {
    @StateObject private var model = MacScreenSharingModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var modifiers: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if let image = model.image, model.connected { viewer(image) }
                else { setup }
            }
            .navigationTitle(model.connected ? model.desktopName : "Mac Screen Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { model.disconnect(); dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.connected {
                        Button { keyboard.toggle() } label: { Image(systemName: "keyboard") }
                            .accessibilityLabel("Toggle on-screen keyboard")
                        Button("Disconnect") { model.disconnect() }
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.background() } }
        .onChange(of: model.connected) { _, _ in zoom = 1; offset = .zero; modifiers = [] }
        .onDisappear { model.disconnect() }
    }
    private var setup: some View {
        Form {
            Section("No Mac companion needed") {
                Label("Connect to macOS’s built-in Screen Sharing", systemImage: "desktopcomputer")
                Text("On your Mac, open System Settings → General → Sharing → Screen Sharing. Turn it on and enable ‘VNC viewers may control screen with password’. Set a separate VNC password (1–8 ASCII characters).")
                Text("Enter the Mac’s local IP address from Network settings, or its hostname such as Mac-mini.local. The Mac and iPad must have a reachable local network connection. A USB cable alone does not enable this mode.")
            }
            Section("Your Mac") {
                TextField("IP address or hostname", text: $model.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).accessibilityIdentifier("vnc.host")
                TextField("Port", text: $model.port).keyboardType(.numberPad)
                SecureField("VNC password (blank uses saved password)", text: $model.password)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vnc.password")
                Toggle("Remember password in Keychain", isOn: $model.remember)
                Button("Forget saved password", role: .destructive) { model.forgetPassword() }
            }.disabled(model.busy)
            Section("Local network connection") {
                Text("Standard VNC does not encrypt the screen or keyboard traffic. Use this mode only on a trusted private network. The VNC password is separate from the 16-digit SidecarBridge code.")
                Toggle("I trust this local network", isOn: $model.localNetworkConsent)
                    .disabled(model.busy)
                Text("This mode displays the existing Mac desktop. Audio and file transfer are not included, and frame rate depends on the Mac’s VNC server. The companion connection remains available for SidecarBridge’s optimized streaming and file transfer.")
            }
            Section {
                Text(model.status).accessibilityIdentifier("vnc.status")
                if model.busy {
                    HStack { ProgressView(); Button("Cancel") { model.disconnect() } }
                } else {
                    Button("Connect") { model.connect() }
                        .disabled(!model.localNetworkConsent || model.host.isEmpty)
                        .accessibilityIdentifier("vnc.connect")
                }
            }
        }
    }
    private func viewer(_ image: CGImage) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(zoom).offset(offset)
                    RemoteInputSurface(contentAspectRatio: CGFloat(image.width) / CGFloat(image.height),
                        zoomScale: zoom, zoomOffset: offset, pointerButtonMapping: .system,
                        calibrateNextPointerClick: false, showsSoftwareKeyboard: keyboard,
                        showsMagicKeyboardPointer: true,
                        onInput: { event in
                            var event = event
                            event.modifiers = Array(Set(event.modifiers ?? []).union(modifiers))
                            model.send(event)
                        },
                        onPasteCommand: { model.send(.key("v", modifiers: ["command"])) },
                        onPointerCalibration: { _ in },
                        onZoom: { factor, _ in
                            guard factor.isFinite, factor > 0 else { return }
                            zoom = min(4, max(1, zoom * factor))
                            let maxX = geometry.size.width * (zoom - 1) / 2
                            let maxY = geometry.size.height * (zoom - 1) / 2
                            offset.width = min(maxX, max(-maxX, offset.width))
                            offset.height = min(maxY, max(-maxY, offset.height))
                        },
                        onViewportPan: { delta in
                            offset.width += delta.width; offset.height += delta.height
                            let maxX = geometry.size.width * (zoom - 1) / 2
                            let maxY = geometry.size.height * (zoom - 1) / 2
                            offset.width = min(maxX, max(-maxX, offset.width))
                            offset.height = min(maxY, max(-maxY, offset.height))
                        })
                }.clipped()
            }
            if keyboard {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(["command", "control", "option", "shift"], id: \.self) { modifier in
                            Button(modifier.capitalized) {
                                if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
                            }.buttonStyle(.bordered).tint(modifiers.contains(modifier) ? .orange : .accentColor)
                        }
                        ForEach(["escape", "tab", "left", "down", "up", "right", "delete"], id: \.self) { key in
                            Button(key.capitalized) { model.send(.key(key, modifiers: Array(modifiers))) }.buttonStyle(.bordered)
                        }
                    }.padding(8)
                }
            }
            Text("VNC • \(image.width) × \(image.height) • Local network")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
    }
}
