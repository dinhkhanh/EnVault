import SwiftUI
import VaultCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            VaultSettings().tabItem { Label("Vault", systemImage: "lock.shield") }
            CommandLineSettings().tabItem { Label("Command Line", systemImage: "terminal") }
            AgentSettings().tabItem { Label("AI Agents", systemImage: "brain.head.profile") }
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
            if TeamFeatures.enabled, model.phase == .unlocked { TeamIdentitySection() }
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
            Section("The envault Command") {
                if CLIService.isBundled {
                    LabeledContent("Installed") {
                        Text(installPath.isEmpty ? "Not yet" : installPath).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    HStack {
                        Button(installPath.isEmpty ? "Install envault Command…" : "Install Again…") { installError = CLIService.installWithPanel() }
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CLIService.bundledCLI]) }
                    }
                    if let installError { Text(installError).font(.callout).foregroundStyle(.red) }
                    Text("Puts a link in a folder on your PATH (Homebrew’s bin works). It points into EnVault, so app updates update the command. Or run this in Terminal:")
                        .font(.callout).foregroundStyle(.secondary)
                    CopyableCommand(CLIService.terminalInstallCommand)
                } else {
                    Text("This build has no bundled command-line tool.").foregroundStyle(.secondary)
                }
            }
            Section("Unlock with Touch ID") {
                Toggle("Let envault ask EnVault for the vault key", isOn: $agentEnabled)
                Text(agentText).font(.callout).foregroundStyle(model.agentRunning ? Color.secondary : Color.red)
            }
            Section("Load Env Files on cd (Pro)") {
                Picker("Shell", selection: $shell) {
                    Text("zsh").tag("zsh"); Text("bash").tag("bash"); Text("fish").tag("fish")
                }
                .pickerStyle(.segmented)
                Text("Add to \(CLIService.shellRCFile(shell)), then in a project folder run `envault link <project> <item>` and `envault unlock`:")
                    .font(.callout).foregroundStyle(.secondary)
                CopyableCommand(CLIService.shellHookLine(shell))
            }
            Section("Block Secrets in Commits") {
                Text("Installs a git pre-commit hook that stops commits containing API keys, tokens or real .env files:")
                    .font(.callout).foregroundStyle(.secondary)
                CopyableCommand("cd your-repo && envault protect")
            }
        }
        .formStyle(.grouped)
    }

    private var agentText: String {
        guard model.agentRunning else { return "Not available: another copy of EnVault is running and answering the command line." }
        return "When the command line needs the key, EnVault asks you with Touch ID (or your Mac password) and hands it over for that one command. Without this, envault asks for the passphrase."
    }
}

struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.cliAgentEnabled) private var cliAgent = true
    @AppStorage(Prefs.agentsEnabled) private var enabled = true
    @AppStorage(Prefs.agentValues) private var values = AIAgents.Policy.Values.ask.rawValue
    @AppStorage(Prefs.agentWrites) private var writes = true
    @AppStorage(Prefs.agentApprovalMinutes) private var minutes = 5
    @State private var copiedGuide = false

    var body: some View {
        Form {
            Section {
                Toggle("Let AI agents use EnVault", isOn: $enabled)
                Text("Claude Code, Cursor, Codex and other agents can run commands with your secrets and see variable names, through the envault command or its MCP server. Secret values in their output are replaced with [redacted:KEY].")
                    .font(.callout).foregroundStyle(.secondary)
                if !cliAgent {
                    Text("Agents can only reach EnVault when “Let envault ask EnVault for the vault key” is on (Command Line).")
                        .font(.callout).foregroundStyle(.red)
                }
            }
            Section("What Agents May Do") {
                Picker("Show secret values", selection: $values) {
                    Text("Ask me each time").tag(AIAgents.Policy.Values.ask.rawValue)
                    Text("Never").tag(AIAgents.Policy.Values.never.rawValue)
                    Text("No extra prompt").tag(AIAgents.Policy.Values.allow.rawValue)
                }
                Toggle("Change env files", isOn: $writes)
                Picker("After I approve an agent", selection: $minutes) {
                    Text("Ask for every command").tag(0)
                    Text("Don’t ask again for 5 minutes").tag(5)
                    Text("Don’t ask again for 15 minutes").tag(15)
                    Text("Don’t ask again for 1 hour").tag(60)
                }
                Text("An agent always needs your approval first. Showing values covers envault get, pull, env, run --no-redact and deploy; “No extra prompt” lets an approved agent do that too. Approvals end when EnVault locks. These are guardrails for well-meaning agents, not a sandbox: an agent with a shell can do whatever your account can.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            Section("Connect an Agent") {
                LabeledContent("Claude Code") { CopyableCommand("claude mcp add envault -- envault mcp") }
                LabeledContent("Codex") { CopyableCommand("codex mcp add envault -- envault mcp") }
                LabeledContent("Cursor, others") { CopyableCommand(#""envault": { "command": "envault", "args": ["mcp"] }"#) }
                HStack {
                    Text("Agents that only use the shell learn the commands from a short guide in AGENTS.md or CLAUDE.md:")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedGuide ? "Copied" : "Copy Guide") {
                        ClipboardService.shared.copy(AIAgents.guide, concealed: false)
                        copiedGuide = true
                        Task { try? await Task.sleep(for: .seconds(1.2)); copiedGuide = false }
                    }
                }
            }
            Section("Recent Requests") {
                if model.agentActivity.isEmpty {
                    Text("Nothing since EnVault started.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.agentActivity.prefix(20)) { AgentActivityRow(entry: $0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentActivityRow: View {
    let entry: AppModel.AgentActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.agent ?? "Terminal") · \(entry.client)")
                Text([entry.detail, entry.note].compactMap { $0 }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var icon: String {
        switch entry.outcome {
        case .approved: "checkmark.circle"
        case .allowed: "clock.arrow.circlepath"
        case .refused: "xmark.circle"
        }
    }

    private var color: Color { entry.outcome == .refused ? .red : entry.purpose == .reveal ? .orange : .secondary }

    private var help: String {
        let what = switch entry.purpose { case .use: "use the vault"; case .write: "change an env file"; case .reveal: "read secret values" }
        return switch entry.outcome {
        case .approved: "Approved to \(what)"
        case .allowed: "Allowed to \(what) by an earlier approval"
        case .refused: "Refused to \(what)"
        }
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

/// Team phase 1 (FR-1, FR-2). Shown while `TeamFeatures.enabled`.
struct TeamIdentitySection: View {
    @Environment(AppModel.self) private var model
    @State private var name = NSFullUserName()

    var body: some View {
        Section("Team Identity") {
            if let identity = model.identity {
                TextField("Name", text: $name)
                    .onSubmit { Task { await model.renameIdentity(name) } }
                LabeledContent("Safety code") {
                    Text(identity.safetyCode).font(.body.monospaced()).textSelection(.enabled)
                }
                Text("A team admin compares this code with you before giving you access. It is the same on every Mac that opens this vault.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Creates the keys teammates use to share vaults with you. They are stored, encrypted, in this vault and sync to your other Macs.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Name", text: $name)
                    Button("Create Identity") { Task { await model.createIdentity(name: name.trimmingCharacters(in: .whitespaces)) } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task {
            await model.loadIdentity()
            if let n = model.identity?.name { name = n }
        }
    }
}
