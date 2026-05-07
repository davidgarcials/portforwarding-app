import SwiftUI
import PortForwardingLib

struct HotkeyRecorderView: View {
    @ObservedObject var hotkeyManager: GlobalHotkeyManager
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { isRecording.toggle() }) {
                Text(displayText)
                    .frame(minWidth: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .background {
                if isRecording {
                    KeyCaptureRepresentable { event in
                        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        guard !mods.isEmpty else { return }
                        let config = HotkeyConfig(keyCode: event.keyCode, modifiers: UInt(mods.rawValue))
                        hotkeyManager.setHotkey(config)
                        isRecording = false
                    }
                    .frame(width: 0, height: 0)
                }
            }

            if hotkeyManager.currentHotkey != nil {
                Button(action: {
                    hotkeyManager.clearHotkey()
                    isRecording = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
    }

    private var displayText: String {
        if isRecording { return "Press shortcut..." }
        if let hotkey = hotkeyManager.currentHotkey {
            return GlobalHotkeyManager.displayString(for: hotkey)
        }
        return "Click to record"
    }
}

// MARK: - NSViewRepresentable for raw key capture

struct KeyCaptureRepresentable: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.isEmpty {
            onKeyDown?(event)
        }
    }
}
