import SwiftUI
import AppKit
import PortForwardingLib

@main
struct PortForwardingApp: App {
    private let notificationService: NotificationService
    @StateObject private var manager: ForwardManager
    @StateObject private var updateChecker = UpdateChecker()

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
            MenuBarView(manager: manager, updateChecker: updateChecker)
        } label: {
            MenuBarIcon(
                hasReady: manager.hasAnyReadyForward,
                hasFailure: manager.hasAnyFailedForward,
                updateChecker: updateChecker
            )
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(manager: manager, updateChecker: updateChecker)
        }
    }
}

struct MenuBarIcon: View {
    var hasReady: Bool
    var hasFailure: Bool
    var updateChecker: UpdateChecker?

    private var badgeColor: NSColor? {
        if hasFailure { return .systemRed }
        if hasReady { return .systemGreen }
        return nil
    }

    var body: some View {
        Group {
            if let image = loadMenuBarImage() {
                Image(nsImage: image)
            } else {
                Image(systemName: "network")
            }
        }
        .onAppear {
            updateChecker?.startPeriodicChecks()
        }
    }

    private func loadMenuBarImage() -> NSImage? {
        let bundlePath = Bundle.main.bundlePath
        let resourcesPath = (bundlePath as NSString).appendingPathComponent("Contents/Resources")

        for path in [resourcesPath, bundlePath] {
            let imagePath = (path as NSString).appendingPathComponent("menubar-icon.png")
            if let img = NSImage(contentsOfFile: imagePath) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                guard let color = badgeColor else { return img }
                return withBadge(img, badgeColor: color)
            }
        }
        return nil
    }

    private func withBadge(_ templateImage: NSImage, badgeColor: NSColor) -> NSImage {
        let size = templateImage.size
        let badgeSize: CGFloat = 6
        let padding: CGFloat = 0.5
        let badgeRect = NSRect(
            x: size.width - badgeSize - padding,
            y: padding,
            width: badgeSize,
            height: badgeSize
        )

        let result = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setFill()
            rect.fill()
            templateImage.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1.0)

            badgeColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        result.isTemplate = false
        return result
    }
}
