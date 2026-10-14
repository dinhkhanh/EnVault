import SwiftUI

@main
struct eVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("eVault", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitPush)) { _ in model.remotePushReceived() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.appActivated() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { NotificationCenter.default.post(name: .newProject, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
                Button("New Item…") { NotificationCenter.default.post(name: .newItem, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(model.phase != .unlocked || model.selectedProjectId == nil)
            }
            CommandMenu("Vault") {
                Button("Lock") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
                Button(model.syncMode == .iCloud ? "Sync with iCloud Now" : "Refresh from Disk") {
                    Task { if model.syncMode == .iCloud { await model.syncNow() } else { await model.refreshFromDisk() } }
                }
                .keyboardShortcut("r")
                .disabled(model.phase == .noVault)
                Divider()
                Button("Reveal Vault Folder in Finder") {
                    if let u = model.vaultURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                .disabled(model.vaultURL == nil)
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra("eVault", systemImage: "key.horizontal.fill") {
            MenuBarView(openMain: { openWindow(id: "main"); NSApp.activate() })
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("evault.newProject")
    static let newItem = Notification.Name("evault.newItem")
}
