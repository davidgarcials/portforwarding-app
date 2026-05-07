import AppKit
import PortForwardingLib

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    @Published var currentHotkey: HotkeyConfig?
    @Published var hasAccessibilityPermission: Bool = false

    var onToggle: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.currentHotkey = configStore.loadAppConfigOrDefault().hotkey
        self.hasAccessibilityPermission = AXIsProcessTrusted()
        registerIfNeeded()
    }

    func setHotkey(_ hotkey: HotkeyConfig?) {
        currentHotkey = hotkey
        var config = configStore.loadAppConfigOrDefault()
        config.hotkey = hotkey
        try? configStore.saveAppConfig(config)
        registerIfNeeded()
    }

    func clearHotkey() {
        setHotkey(nil)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
    }

    func refreshAccessibilityStatus() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        if hasAccessibilityPermission {
            registerIfNeeded()
        }
    }

    private func registerIfNeeded() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        guard let hotkey = currentHotkey else { return }

        let maskedModifiers = hotkey.modifiers & 0xFFFF0000
        let handler: (NSEvent) -> Void = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue & 0xFFFF0000
            guard event.keyCode == hotkey.keyCode, eventMods == maskedModifiers else { return }
            Task { @MainActor in
                self?.onToggle?()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    static func displayString(for config: HotkeyConfig) -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: UInt(config.modifiers))
        if mods.contains(.control) { parts.append("\u{2303}") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }
        parts.append(keyName(for: config.keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let mapping: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
            0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
            0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
            0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
            0x25: "L", 0x26: "J", 0x28: "K", 0x2C: "/", 0x2D: "N",
            0x2E: "M", 0x2F: ",", 0x2B: ".", 0x24: "\u{21A9}",
            0x30: "\u{21E5}", 0x31: "\u{2423}", 0x33: "\u{232B}",
            0x35: "\u{238B}", 0x7A: "F1", 0x78: "F2", 0x63: "F3",
            0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
            0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11",
            0x6F: "F12",
        ]
        return mapping[keyCode] ?? "Key(\(keyCode))"
    }
}
