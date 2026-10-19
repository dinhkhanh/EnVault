import SwiftUI

@main
struct EnVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var licenses: LicenseManager
    @Environment(\.openWindow) private var openWindow

    init() {
        let model = AppModel()
        let licenses = LicenseManager()
        _model = State(initialValue: model)
        _licenses = State(initialValue: licenses)
        QuickCopyPanelController.shared.configure(model: model, licenses: licenses)
        model.bootstrap()
    }

    var body: some Scene {
        Window("EnVault", id: "main") {
            RootView()
                .environment(model)
                .environment(licenses)
                .sheet(isPresented: Binding(get: { licenses.upgradePrompt != nil }, set: { if !$0 { licenses.upgradePrompt = nil } })) {
                    UpgradeSheet(feature: licenses.upgradePrompt).environment(licenses)
                }
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await model.start()
                    QuickCopyPanelController.shared.openMain = { openWindow(id: "main"); NSApp.activate() }
                }
                // Pushes for vaults shared with this account don't concern the vault open here.
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitPush)) { note in
                    if note.userInfo?["subscriptionID"] as? String != "envault-shared" { model.remotePushReceived() }
                }
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: .showTeamSpike)) { _ in openWindow(id: "team-spike") }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.appActivated() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterService.shared.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { NotificationCenter.default.post(name: .newProject, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
                Button("New Item…") { NotificationCenter.default.post(name: .newItem, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(model.phase != .unlocked || model.selectedProjectId == nil)
                Divider()
                Button("Import Projects from Folder…") { NotificationCenter.default.post(name: .importProjects, object: nil) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
            }
            CommandMenu("Vault") {
                Button("Lock") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
                Button("Quick Copy…") { QuickCopyPanelController.shared.show() }
                    .disabled(model.phase == .noVault)
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
                #if DEBUG
                Divider()
                Button("Team Spike…") { openWindow(id: "team-spike") }
                    .disabled(!model.cloudAvailable)
                Button("Attach Another Vault…") { openWindow(id: "attach-vault") }
                    .disabled(model.phase != .unlocked)
                #endif
            }
        }

        #if DEBUG
        Window("Team Spike", id: "team-spike") {
            TeamSpikeView().environment(model)
        }
        Window("Attach Vault", id: "attach-vault") {
            AttachVaultView().environment(model)
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            SettingsView().environment(model).environment(licenses)
        }

        MenuBarExtra("EnVault", systemImage: "key.horizontal.fill") {
            MenuBarView(openMain: { openWindow(id: "main"); NSApp.activate() })
                .environment(model)
                .environment(licenses)
        }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("envault.newProject")
    static let newItem = Notification.Name("envault.newItem")
    static let importProjects = Notification.Name("envault.importProjects")
}
