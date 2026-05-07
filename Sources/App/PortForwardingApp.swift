import SwiftUI
import AppKit
import PortForwardingLib

@main
struct PortForwardingApp: App {
    private let notificationService: NotificationService
    @StateObject private var manager: ForwardManager

    init() {
        let notifier = NotificationService()
        notifier.requestPermission()
        self.notificationService = notifier
        let mgr = ForwardManager(configStore: ConfigStore(), notifier: notifier)
        self._manager = StateObject(wrappedValue: mgr)
        notifier.onReconnectRequested = { [weak mgr] forwardId in
            Task { @MainActor in
                mgr?.reconnect(forwardId: forwardId)
            }
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
            SettingsView(manager: manager)
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
