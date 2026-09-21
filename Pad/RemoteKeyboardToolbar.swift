import SwiftUI

struct OfflineKeyboardDiagnosticView: View {
    @State private var mode: SoftwareKeyboardMode = .standard
    @State private var modifiers: Set<String> = []
    @State private var diagnostic = KeyboardDiagnosticState()
    @State private var keyboardVisible = true

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Local test • no Mac required", systemImage: "checkmark.shield")
                            .font(.headline)
                        Text("Uses the same custom keyboard as the remote viewer. Keys stay on this device; nothing is sent, saved, or pasted. Shortcuts and language keys are logged, not executed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(diagnostic.text.isEmpty ? "Type on the keyboard below…" : diagnostic.text)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Test output")
                        Text("\(diagnostic.keyCount) keys • Held: \(modifiers.isEmpty ? "none" : modifiers.sorted().joined(separator: ", "))")
                            .font(.caption)
                        DisclosureGroup("Recent key events") {
                            ForEach(Array(diagnostic.events.enumerated()), id: \.offset) { _, event in
                                Text(event).font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !keyboardVisible {
                            Button("Show test keyboard") { keyboardVisible = true }
                        }
                    }.padding(.horizontal)
                }
                if keyboardVisible {
                    let panel = SoftwareKeyboardLayout.panelSize(in: geometry.size)
                    RemoteKeyboardToolbar(
                        mode: $mode, modifiers: $modifiers,
                        onKey: { diagnostic.record($0, modifiers: $1) },
                        onShortcut: { diagnostic.record($0, modifiers: Set($1)) },
                        onInputMode: { diagnostic.record("Chinese / English") },
                        onCycleInputMode: { diagnostic.record("Next input source") },
                        onClearModifiers: { modifiers.removeAll() },
                        onHide: { keyboardVisible = false; modifiers.removeAll() },
                        maximumHeight: panel.height - 16
                    )
                    .padding(.horizontal, 2).padding(.vertical, 8)
                    .frame(width: panel.width, height: panel.height)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .environment(\.colorScheme, .dark)
                }
            }.padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Keyboard test")
        .toolbar {
            Button("Clear") { diagnostic = KeyboardDiagnosticState(); modifiers.removeAll() }
        }
    }
}

enum SoftwareKeyboardMode: String, CaseIterable, Identifiable {
    case standard
    case special

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .special: return "Special"
        }
    }
}

struct RemoteKeyboardToolbar: View {
    @Binding var mode: SoftwareKeyboardMode
    @Binding var modifiers: Set<String>
    @State private var showsSymbols = false

    let onKey: (String, Set<String>) -> Void
    let onShortcut: (String, [String]) -> Void
    let onInputMode: () -> Void
    let onCycleInputMode: () -> Void
    let onClearModifiers: () -> Void
    let onHide: () -> Void
    var maximumHeight: CGFloat? = nil

    private let functionKeys = (1...12).map { "f\($0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(0.84))
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(SoftwareKeyboardMode.allCases) { item in
                        Button { mode = item } label: {
                            Text(item.title).font(.caption.bold())
                                .frame(width: 70, height: 44)
                                .background(mode == item ? Color.cyan.opacity(0.5) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(mode == item ? .isSelected : [])
                    }
                }
                .accessibilityLabel("Remote keyboard mode")
                Button(action: onHide) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")
            }

            if let maximumHeight {
                ScrollView(.vertical) {
                    keyboardContent
                }
                .frame(height: max(0, maximumHeight - 64))
            } else {
                keyboardContent
            }

        }
        .padding(6)
        .accessibilityElement(children: .contain)
    }

    private var keyboardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .special {
                modifierRow
                keyRow([
                    ("Esc", "escape"),
                    ("Tab", "tab"),
                    ("Caps", "capslock"),
                    ("Delete", "delete"),
                    ("Forward", "forwarddelete"),
                    ("Return", "return"),
                    ("Space", "space")
                ])

                keyRow([
                    ("Home", "home"),
                    ("End", "end"),
                    ("Pg Up", "pageup"),
                    ("Pg Dn", "pagedown"),
                    ("←", "left"),
                    ("↑", "up"),
                    ("↓", "down"),
                    ("→", "right")
                ])

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                        ForEach(functionKeys, id: \.self) { key in
                            keyButton(title: key.uppercased(), key: key, width: 42)
                        }
                }

                shortcutRow
                inputModeRow.frame(height: 44)
            } else {
                basicKeyboard
            }

        }
    }

    private var basicKeyboard: some View {
        GeometryReader { geometry in
            typingLayout(wide: geometry.size.width >= 600)
        }
        .frame(height: max(252, (maximumHeight ?? 384) - 64))
    }

    private func typingLayout(wide: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                modifierButton(title: "⌘", name: "Command", key: "command")
                modifierButton(title: "⌥", name: "Option", key: "option")
                modifierButton(title: "⌃", name: "Control", key: "control")
                keyButton(title: "Tab", key: "tab")
                Button(action: onClearModifiers) {
                    Image(systemName: "xmark.circle").frame(width: 44, height: 44)
                }.disabled(modifiers.isEmpty).accessibilityLabel("Release held modifiers")
            }
            HStack(spacing: 6) {
                letterRow(showsSymbols ? "1234567890" : "qwertyuiop", wide: wide)
                if wide {
                    keyButton(title: "⌫", key: "delete").frame(width: 80)
                        .accessibilityLabel("Backspace")
                }
            }
            HStack(spacing: 6) {
                letterRow(showsSymbols ? "-=[]\\;'/" : "asdfghjkl", wide: wide)
                if wide {
                    keyButton(title: "return", key: "return").frame(width: 110)
                }
            }.padding(.leading, wide ? 28 : 14)
                .padding(.trailing, wide ? 0 : 14)
            HStack(spacing: 6) {
                modifierButton(title: "⇧", name: "Shift", key: "shift").frame(width: wide ? 80 : 44)
                letterRow(showsSymbols ? ",.`" : "zxcvbnm", wide: wide)
                if wide {
                    keyButton(title: ",", key: ",").frame(width: 56)
                    keyButton(title: ".", key: ".").frame(width: 56)
                    modifierButton(title: "⇧", name: "Shift", key: "shift").frame(width: 80)
                } else {
                    keyButton(title: "⌫", key: "delete").frame(width: 44)
                        .accessibilityLabel("Backspace")
                }
            }
            HStack(spacing: 6) {
                Button { showsSymbols.toggle() } label: {
                    Text(showsSymbols ? "ABC" : "123").font(.callout).frame(width: wide ? 80 : 44, height: 44)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(RemoteKeyPressStyle()).accessibilityLabel(showsSymbols ? "Letters" : "Numbers and symbols")
                Button(action: onInputMode) {
                    Image(systemName: "globe").font(.title3).frame(width: 36, height: 44)
                }.buttonStyle(RemoteKeyPressStyle()).accessibilityLabel("Toggle Chinese and English")
                keyButton(title: "space", key: "space")
                    .layoutPriority(1)
                if wide {
                    Button(action: onCycleInputMode) {
                        Image(systemName: "globe").frame(width: 60, height: 52)
                    }.accessibilityLabel("Next input source")
                } else {
                    keyButton(title: "return", key: "return").frame(width: 70)
                        .accessibilityLabel("Return")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func letterRow(_ row: String, wide: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(row).map(String.init), id: \.self) { key in
                Button { onKey(key, modifiers) } label: {
                    Text(SoftwareKeyboardLayout.title(for: key, shift: modifiers.contains("shift")))
                        .font(.system(size: wide ? 24 : 23, weight: .regular))
                        .frame(maxWidth: .infinity, minHeight: wide ? 56 : 44)
                        .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(RemoteKeyPressStyle(preview: wide ? nil : SoftwareKeyboardLayout.title(for: key, shift: modifiers.contains("shift"))))
            }
        }
    }

    private var modifierRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                modifierButton(title: "⌘", name: "Command", key: "command")
                modifierButton(title: "⌥", name: "Option", key: "option")
                modifierButton(title: "⌃", name: "Control", key: "control")
                modifierButton(title: "⇧", name: "Shift", key: "shift")
            }
            HStack(spacing: 5) {
                    modifierButton(title: "⌘", name: "Command", key: "command")
                    modifierButton(title: "⌥", name: "Option", key: "option")
                    modifierButton(title: "⌃", name: "Control", key: "control")
                    modifierButton(title: "⇧", name: "Shift", key: "shift")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Common shortcuts")
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.64))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 5)], spacing: 5) {
                    shortcutButton("⌘C", key: "c", modifiers: ["command"], description: "Copy")
                    shortcutButton("⌘V", key: "v", modifiers: ["command"], description: "Paste")
                    shortcutButton("⌘X", key: "x", modifiers: ["command"], description: "Cut")
                    shortcutButton("⌘A", key: "a", modifiers: ["command"], description: "Select all")
                    shortcutButton("⌘Z", key: "z", modifiers: ["command"], description: "Undo")
                    shortcutButton("⇧⌘Z", key: "z", modifiers: ["command", "shift"], description: "Redo")
                    shortcutButton("⌘Tab", key: "tab", modifiers: ["command"], description: "Switch app")
            }
        }
    }

    private var inputModeRow: some View {
        HStack(spacing: 5) {
            Button {
                onInputMode()
            } label: {
                Label("中/英", systemImage: "character.cursor.ibeam")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .tint(.purple)
            .accessibilityLabel("Toggle Chinese and English input")

            Button {
                onCycleInputMode()
            } label: {
                Label("Globe", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cycle Mac input source")
        }
    }

    private func keyRow(_ keys: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 5)], spacing: 5) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, item in
                    keyButton(title: item.0, key: item.1)
                }
        }
    }

    private func modifierButton(title: String, name: String, key: String) -> some View {
        let isActive = modifiers.contains(key)
        return Button {
            if isActive {
                modifiers.remove(key)
            } else {
                modifiers.insert(key)
            }
        } label: {
            Text(title)
                .font(.headline.bold())
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isActive ? Color.cyan.opacity(0.65) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(RemoteKeyPressStyle())
        .tint(isActive ? .cyan : .white.opacity(0.18))
        .accessibilityLabel("\(name) modifier")
        .accessibilityValue(isActive ? "Held" : "Not held")
    }

    private func keyButton(title: String, key: String, width: CGFloat = 58) -> some View {
        Button {
            onKey(key, modifiers)
        } label: {
            Text(title)
                .font(.system(size: 15))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(RemoteKeyPressStyle())
        .tint(.white.opacity(0.86))
        .accessibilityLabel(title)
        .accessibilityHint(modifiers.isEmpty ? "Send key" : "Send key with held modifiers")
    }

    private func shortcutButton(
        _ title: String,
        key: String,
        modifiers: [String],
        description: String
    ) -> some View {
        Button {
            onShortcut(key, modifiers)
        } label: {
            Text(title)
                .font(.caption2.bold())
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.indigo.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .tint(.indigo)
        .accessibilityLabel(description)
    }
}

/// Immediate touch-down feedback; the Button still sends exactly once on release
/// and cancels normally when the finger leaves its hit region.
private struct RemoteKeyPressStyle: ButtonStyle {
    var preview: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(configuration.isPressed ? 0.24 : 0))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if configuration.isPressed, let preview {
                    Text(preview)
                        .font(.system(size: 32))
                        .frame(minWidth: 48, minHeight: 54)
                        .background(Color(white: 0.38), in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        .offset(y: -48)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(configuration.isPressed ? 10 : 0)
            #if os(iOS)
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in
                pressed
            }
            #endif
    }
}
