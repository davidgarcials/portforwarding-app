import SwiftUI
import AppKit
import PortForwardingLib

@main
struct PortForwardingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let notificationService: NotificationService
    @StateObject private var manager: ForwardManager
    @StateObject private var hotkeyManager: GlobalHotkeyManager

    init() {
        let store = ConfigStore()

        let notifier = NotificationService()
        notifier.requestPermission()
        self.notificationService = notifier

        let mgr = ForwardManager(configStore: store, notifier: notifier)
        self._manager = StateObject(wrappedValue: mgr)

        let hkManager = GlobalHotkeyManager(configStore: store)
        self._hotkeyManager = StateObject(wrappedValue: hkManager)

        notifier.onReconnectRequested = { [weak mgr] forwardId in
            Task { @MainActor in
                mgr?.reconnect(forwardId: forwardId)
            }
        }

        hkManager.onToggle = {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(manager: manager, hotkeyManager: hotkeyManager)
        }
    }
}

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettingsWindow,
            object: nil
        )
    }

    @objc private func handleOpenSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Settings" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct MenuBarIcon: View {
    var body: some View {
        if let image = loadTemplateImage() {
            Image(nsImage: image)
        } else {
            Image(systemName: "network")
        }
    }

    private func loadTemplateImage() -> NSImage? {
        let bundlePath = Bundle.main.bundlePath
        let resourcesPath = (bundlePath as NSString).appendingPathComponent("Contents/Resources")

        for path in [resourcesPath, bundlePath] {
            let imagePath = (path as NSString).appendingPathComponent("menubar-icon.png")
            if let img = NSImage(contentsOfFile: imagePath) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return nil
    }
}
