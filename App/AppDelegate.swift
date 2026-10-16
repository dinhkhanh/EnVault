import AppKit
import CloudKit
import os

/// Receives CloudKit silent pushes and forwards them to the model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "dk.dinhkhanh.envault", category: "push")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
        _ = UpdaterService.shared
        HotKeyService.shared.action = { QuickCopyPanelController.shared.toggle() }
        HotKeyService.shared.apply()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        NotificationCenter.default.post(name: .cloudKitPush, object: nil)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.log.info("remote notifications unavailable: \(error.localizedDescription, privacy: .public)")
    }
}

extension Notification.Name {
    static let cloudKitPush = Notification.Name("envault.cloudKitPush")
}
