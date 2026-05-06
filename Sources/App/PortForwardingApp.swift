import SwiftUI
import AppKit
import PortForwardingLib

@main
struct PortForwardingApp: App {
    @StateObject private var manager = ForwardManager(configStore: ConfigStore())

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
