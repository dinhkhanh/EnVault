import SwiftUI
import VaultCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            VaultSettings().tabItem { Label("Vault", systemImage: "lock.shield") }
            CommandLineSettings().tabItem { Label("Command Line", systemImage: "terminal") }
            LicenseSettings().tabItem { Label("License", systemImage: "sparkles") }
        }
        .frame(width: 480)
        .padding()
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.autoLockMinutes) private var autoLock = 15
    @AppStorage(Prefs.clipboardClearSeconds) private var clipboard = 30
    @AppStorage(Prefs.maskValues) private var mask = true
    @AppStorage(Prefs.autoMaskSeconds) private var autoMask = 30
    @AppStorage(Prefs.lockOnSleep) private var lockOnSleep = true
    @AppStorage(Prefs.quickCopyHotKey) private var hotKey = HotKeyService.Preset.optCmdE.rawValue
    @State private var hotKeyTaken = false

    var body: some View {
        Form {
            Picker("Auto-lock after", selection: $autoLock) {
                Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("1 hour").tag(60); Text("Never").tag(0)
            }
            Toggle("Lock when the Mac sleeps or the screen locks", isOn: $lockOnSleep)
            Picker("Clear clipboard after", selection: $clipboard) {
                Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("Never").tag(0)
            }
            Toggle("Mask values by default", isOn: $mask)
            Picker("Mask again after revealing", selection: $autoMask) {
                Text("10 seconds").tag(10); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("Never").tag(0)
            }
            .disabled(!mask)
            Section("Quick Copy") {
                Picker("Shortcut", selection: $hotKey) {
                    ForEach(HotKeyService.Preset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, _ in
                    HotKeyService.shared.apply()
                    hotKeyTaken = HotKeyService.Preset.current != .off && !HotKeyService.shared.registered
                }
                if hotKeyTaken {
                    Text("Another app already uses this shortcut. Pick a different one.").font(.callout).foregroundStyle(.red)
                } else {
                    Text("Opens a search panel over any app: type, then ↩ to copy. Also in the menu bar.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { UpdaterService.shared.automaticallyChecks }, set: { UpdaterService.shared.automaticallyChecks = $0 }))
                Button("Check Now") { UpdaterService.shared.checkForUpdates() }
            }
        }
        .formStyle(.grouped)
    }
}

struct VaultSettings: View {
    @Environment(AppModel.self) private var model
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Location") {
                if model.syncMode == .iCloud {
                    LabeledContent("Sync") { Label("iCloud (CloudKit)", systemImage: "icloud") }
                    LabeledContent("Vault id") { Text(model.vaultId?.uuidString ?? "—").font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("Status") {
                        switch model.syncStatus {
                        case .idle: Text(model.lastCloudSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                        case .syncing: Text("Syncing…")
                        case .error(let e): Text(e).foregroundStyle(.red)
                        }
                    }
                    HStack {
                        Button("Sync Now") { Task { await model.syncNow() } }
                        Button("Reset Sync State") { Task { await model.resetCloudState() } }
                            .help("Forget what has been uploaded/downloaded and re-check everything against iCloud. Files are never deleted by this.")
                    }
                    Text("Other Macs signed in to the same iCloud account can open this vault from the welcome screen with the passphrase.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Folder") {
                        Text(model.vaultURL?.path(percentEncoded: false) ?? "—").textSelection(.enabled).font(.callout)
                    }
                    if model.isInICloudDrive {
                        Label("Inside iCloud Drive: other Macs signed into this Apple Account get the vault automatically.", systemImage: "icloud")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Button("Close Vault…") { model.closeVault() }
            }
            Section("Recovery Key") {
                Text(model.hasRecoveryKey ? "A recovery key exists. Generating a new one invalidates the old one." : "No recovery key. Without one, a forgotten passphrase means the vault is lost.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.hasRecoveryKey ? "Generate New Recovery Key…" : "Create Recovery Key…") {
                    Task { model.pendingRecoveryKey = await model.createRecoveryKey() }
                }
                .disabled(model.phase != .unlocked)
            }
            Section("Touch ID") {
                if model.hasBiometricKey {
                    Button("Disable Touch ID Unlock") { model.disableBiometrics() }
                } else {
                    Text(model.biometricsAvailable ? "Enable it on the lock screen the next time you enter the passphrase." : "Touch ID is not available on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Change Passphrase") {
                SecureField("Current passphrase", text: $current)
                SecureField("New passphrase", text: $new1)
                SecureField("Confirm new passphrase", text: $new2)
                HStack {
                    if let m = message { Text(m).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Change") {
                        Task {
                            let ok = await model.changePassphrase(current: current, new: new1)
                            message = ok ? "Passphrase changed. Touch ID stays valid." : model.errorMessage
                            if ok { current = ""; new1 = ""; new2 = "" }
                        }
                    }
                    .disabled(model.phase != .unlocked || current.isEmpty || new1.count < 8 || new1 != new2)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CommandLineSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.cliAgentEnabled) private var agentEnabled = true
    @AppStorage(Prefs.cliInstallPath) private var installPath = ""
    @State private var installError: String?
    @State private var shell = "zsh"

    var body: some View {
        Form {
            Section("The evault Command") {
                if CLIService.isBundled {
                    LabeledContent("Installed") {
                        Text(installPath.isEmpty ? "Not yet" : installPath).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    HStack {
                        Button(installPath.isEmpty ? "Install evault Command…" : "Install Again…") { installError = CLIService.installWithPanel() }
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CLIService.bundledCLI]) }
                    }
                    if let installError { Text(installError).font(.callout).foregroundStyle(.red) }
                    Text("Puts a link in a folder on your PATH (Homebrew’s bin works). It points into eVault, so app updates update the command. Or run this in Terminal:")
                        .font(.callout).foregroundStyle(.secondary)
                    CopyableCommand(CLIService.terminalInstallCommand)
                } else {
                    Text("This build has no bundled command-line tool.").foregroundStyle(.secondary)
                }
            }
            Section("Unlock with Touch ID") {
                Toggle("Let evault ask eVault for the vault key", isOn: $agentEnabled)
                Text(agentText).font(.callout).foregroundStyle(model.agentRunning ? Color.secondary : Color.red)
            }
            Section("Load Env Files on cd (Pro)") {
                Picker("Shell", selection: $shell) {
                    Text("zsh").tag("zsh"); Text("bash").tag("bash"); Text("fish").tag("fish")
                }
                .pickerStyle(.segmented)
                Text("Add to \(CLIService.shellRCFile(shell)), then in a project folder run `evault link <project> <item>` and `evault unlock`:")
                    .font(.callout).foregroundStyle(.secondary)
                CopyableCommand(CLIService.shellHookLine(shell))
            }
            Section("Block Secrets in Commits") {
                Text("Installs a git pre-commit hook that stops commits containing API keys, tokens or real .env files:")
                    .font(.callout).foregroundStyle(.secondary)
                CopyableCommand("cd your-repo && evault protect")
            }
        }
        .formStyle(.grouped)
    }

    private var agentText: String {
        guard model.agentRunning else { return "Not available: another copy of eVault is running and answering the command line." }
        return "When the command line needs the key, eVault asks you with Touch ID (or your Mac password) and hands it over for that one command. Without this, evault asks for the passphrase."
    }
}

/// A one-line command with a copy button.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false
    init(_ command: String) { self.command = command }

    var body: some View {
        HStack {
            Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer()
            Button {
                ClipboardService.shared.copy(command, concealed: false)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy")
        }
    }
}
