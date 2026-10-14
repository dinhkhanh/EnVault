import SwiftUI
import VaultCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            VaultSettings().tabItem { Label("Vault", systemImage: "lock.shield") }
        }
        .frame(width: 480)
        .padding()
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.autoLockMinutes) private var autoLock = 15
    @AppStorage(Prefs.clipboardClearSeconds) private var clipboard = 30
    @AppStorage(Prefs.maskValues) private var mask = true
    @AppStorage(Prefs.lockOnSleep) private var lockOnSleep = true

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
