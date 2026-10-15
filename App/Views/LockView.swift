import SwiftUI
import VaultCore

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var passphrase = ""
    /// Starts checked if Touch ID was enabled before, so a lost keychain item is re-saved on the next passphrase unlock.
    @State private var remember = UserDefaults.standard.bool(forKey: Prefs.biometricUnlock)
    @State private var busy = false
    @State private var useRecovery = false
    @State private var recoveryKey = ""
    @FocusState private var focused: Bool

    private var working: Bool { busy || model.unlockProgress != nil }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Vault Locked").font(.title2.bold())
            if model.syncMode == .iCloud {
                Label("Synced with iCloud", systemImage: "icloud").font(.callout).foregroundStyle(.secondary)
                SyncStatusLabel()
            } else if let url = model.vaultURL {
                Label(url.lastPathComponent, systemImage: model.isInICloudDrive ? "icloud" : "folder")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(url.path(percentEncoded: false))
            }

            VStack(spacing: 10) {
                if useRecovery {
                    TextField("Recovery key (EVLT-…)", text: $recoveryKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($focused)
                        .onSubmit(submitRecovery)
                        .disabled(working)
                    HStack {
                        Button("Back to passphrase") { useRecovery = false }
                        Spacer()
                        Button(action: submitRecovery) { unlockLabel("Unlock with Recovery Key") }
                            .buttonStyle(.borderedProminent)
                            .disabled(RecoveryKey.normalize(recoveryKey) == nil || working)
                    }
                } else {
                SecureField(model.hasBiometricKey ? "Passphrase, or press Return for Touch ID" : "Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(working)
                if model.biometricsAvailable && !model.hasBiometricKey {
                    Toggle("Remember on this Mac and unlock with Touch ID", isOn: $remember)
                        .font(.callout)
                }
                HStack {
                    if model.hasBiometricKey {
                        Button { Task { await model.unlockWithBiometrics() } } label: {
                            Label("Touch ID", systemImage: "touchid")
                        }
                        .disabled(working)
                    }
                    Spacer()
                    Button(action: submit) { unlockLabel("Unlock") }
                        .buttonStyle(.borderedProminent)
                        .disabled(passphrase.isEmpty || working)
                }
                if model.hasRecoveryKey {
                    Button("Forgot passphrase? Use recovery key") { useRecovery = true; model.errorMessage = nil }
                        .buttonStyle(.link).font(.caption)
                }
                }
            }
            .frame(width: 360)

            if let p = model.unlockProgress {
                progressView(p).frame(width: 360)
            } else if let e = model.errorMessage {
                Text(e).foregroundStyle(.red).font(.callout)
            }
            Button("Use a different vault…") { model.closeVault() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func unlockLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small) }
            Text(working ? "Unlocking…" : title)
        }
    }

    @ViewBuilder private func progressView(_ p: AppModel.UnlockProgress) -> some View {
        switch p {
        case .checking:
            Text("Checking key…").font(.callout).foregroundStyle(.secondary)
        case .decrypting(let done, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Decrypting vault… \(done) of \(total) revisions").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func submitRecovery() {
        guard RecoveryKey.normalize(recoveryKey) != nil, !working else { return }
        busy = true
        let k = recoveryKey
        Task {
            await model.unlock(recoveryKey: k)
            recoveryKey = ""
            busy = false
        }
    }

    private func submit() {
        guard !working else { return }
        if passphrase.isEmpty {
            if model.hasBiometricKey { Task { await model.unlockWithBiometrics() } }
            return
        }
        busy = true
        let p = passphrase
        Task {
            await model.unlock(passphrase: p, rememberWithBiometrics: remember)
            passphrase = ""
            busy = false
        }
    }
}
