import Foundation
import UserNotifications

public protocol PortDropNotifying: AnyObject {
    var onReconnectRequested: ((UUID) -> Void)? { get set }
    func requestPermission()
    func sendPortDropped(forward: PortForward)
}

public final class NotificationService: NSObject, PortDropNotifying, UNUserNotificationCenterDelegate {
    private static let categoryIdentifier = "PORT_DROPPED"
    private static let reconnectActionIdentifier = "RECONNECT"

    public var onReconnectRequested: ((UUID) -> Void)?

    public override init() {
        super.init()
        let reconnectAction = UNNotificationAction(
            identifier: Self.reconnectActionIdentifier,
            title: "Reconnect",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [reconnectAction],
            intentIdentifiers: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func sendPortDropped(forward: PortForward) {
        let content = UNMutableNotificationContent()
        content.title = "\(forward.name) disconnected"
        content.body = "Port \(forward.localPort) lost connection"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = forward.id.uuidString
        content.userInfo = ["forwardId": forward.id.uuidString]

        let request = UNNotificationRequest(
            identifier: forward.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.reconnectActionIdentifier,
              let idString = response.notification.request.content.userInfo["forwardId"] as? String,
              let forwardId = UUID(uuidString: idString)
        else { return }
        onReconnectRequested?(forwardId)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
