import SwiftUI
import VaultCore

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var passphrase = ""
    @State private var remember = false
    @State private var busy = false
    @State private var useRecovery = false
    @State private var recoveryKey = ""
    @FocusState private var focused: Bool

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
                    HStack {
                        Button("Back to passphrase") { useRecovery = false }
                        Spacer()
                        Button("Unlock with Recovery Key", action: submitRecovery)
                            .buttonStyle(.borderedProminent)
                            .disabled(RecoveryKey.normalize(recoveryKey) == nil || busy)
                    }
                } else {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if model.biometricsAvailable && !model.hasBiometricKey {
                    Toggle("Remember on this Mac and unlock with Touch ID", isOn: $remember)
                        .font(.callout)
                }
                HStack {
                    if model.hasBiometricKey {
                        Button { Task { await model.unlockWithBiometrics() } } label: {
                            Label("Touch ID", systemImage: "touchid")
                        }
                    }
                    Spacer()
                    Button("Unlock", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(passphrase.isEmpty || busy)
                }
                if model.hasRecoveryKey {
                    Button("Forgot passphrase? Use recovery key") { useRecovery = true; model.errorMessage = nil }
                        .buttonStyle(.link).font(.caption)
                }
                }
            }
            .frame(width: 360)

            if let e = model.errorMessage {
                Text(e).foregroundStyle(.red).font(.callout)
            }
            Button("Use a different vault…") { model.closeVault() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            if model.hasBiometricKey { Task { await model.unlockWithBiometrics() } }
        }
    }

    private func submitRecovery() {
        guard RecoveryKey.normalize(recoveryKey) != nil else { return }
        busy = true
        let k = recoveryKey
        Task {
            await model.unlock(recoveryKey: k)
            recoveryKey = ""
            busy = false
        }
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        busy = true
        let p = passphrase
        Task {
            await model.unlock(passphrase: p, rememberWithBiometrics: remember)
            passphrase = ""
            busy = false
        }
    }
}
