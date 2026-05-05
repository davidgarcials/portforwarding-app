import SwiftUI
import PortForwardingLib

@main
struct PortForwardingApp: App {
    @StateObject private var manager = ForwardManager(configStore: ConfigStore())

    var body: some Scene {
        MenuBarExtra("PortForwarding", systemImage: "network") {
            MenuBarView(manager: manager)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(manager: manager)
        }
    }
}
