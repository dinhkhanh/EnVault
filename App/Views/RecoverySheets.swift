import SwiftUI
import VaultCore

/// Shows a recovery key exactly once and insists the user stores it.
struct RecoveryKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let recoveryKey: String
    let onDone: () -> Void
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your recovery key", systemImage: "key.horizontal").font(.title2.bold())
            Text("If you forget your passphrase, this key is the only way back into the vault. It is shown once. Store it in a password manager or print it.")
                .foregroundStyle(.secondary)
            Text(recoveryKey)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button { ClipboardService.shared.copy(recoveryKey, concealed: true); copied = true } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button { save() } label: { Label("Save as Text File…", systemImage: "square.and.arrow.down") }
                Spacer()
            }
            Toggle("I have stored this key somewhere safe", isOn: $saved)
            HStack {
                Spacer()
                Button("Done") { onDone(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saved)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "eVault recovery key.txt"
        panel.message = "Store this file somewhere safe, not inside the vault folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "eVault recovery key\nCreated \(Date().formatted())\n\n\(recoveryKey)\n\nUse it on the lock screen under “Use recovery key” if you forget your passphrase.\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        saved = true
    }
}

/// After a recovery-key unlock: pick a new passphrase.
struct SetPassphraseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Choose a new passphrase", systemImage: "lock.rotation").font(.title2.bold())
            Text("You unlocked with the recovery key. Set a passphrase now; the recovery key stays valid.")
                .foregroundStyle(.secondary)
            SecureField("New passphrase", text: $new1)
            SecureField("Confirm new passphrase", text: $new2)
            HStack {
                Spacer()
                Button("Set Passphrase") {
                    busy = true
                    Task { if await model.resetPassphrase(new: new1) { dismiss() }; busy = false }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(new1.count < 8 || new1 != new2 || busy)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
