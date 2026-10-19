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
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return }
        NotificationCenter.default.post(name: .cloudKitPush, object: nil, userInfo: note.subscriptionID.map { ["subscriptionID": $0] })
    }

    /// A vault share link opened from Mail, Messages or Safari (`CKSharingSupported`).
    /// Only debug builds can join shared vaults so far (Team phase 0 spike).
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        #if DEBUG
        TeamSpikeModel.shared.accept(metadata)
        #else
        let alert = NSAlert()
        alert.messageText = "Shared vaults aren't available yet"
        alert.informativeText = "This link opens a vault someone shared with you. Team sharing comes in a later version of EnVault."
        alert.runModal()
        #endif
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.log.info("remote notifications unavailable: \(error.localizedDescription, privacy: .public)")
    }
}

extension Notification.Name {
    static let cloudKitPush = Notification.Name("envault.cloudKitPush")
}
