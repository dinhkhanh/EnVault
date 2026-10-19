#if DEBUG
import SwiftUI
import AppKit

/// Debug only until team vaults exist (phase 2): attaches another folder
/// vault next to the personal one so the sidebar's vault switcher can be tried.
struct AttachVaultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var passphrase = ""
    @State private var working = false

    var body: some View {
        Form {
            LabeledContent("Folder") {
                HStack {
                    Text(folder?.path(percentEncoded: false) ?? "None").foregroundStyle(folder == nil ? .secondary : .primary)
                    Button("Choose…") { choose() }
                }
            }
            SecureField("Passphrase", text: $passphrase)
            Text("The vault stays attached until EnVault locks. Team vaults will attach this way in phase 2, unlocked by your identity instead of a passphrase.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Attach") {
                    guard let folder else { return }
                    working = true
                    Task {
                        await model.attachVault(at: folder, passphrase: passphrase)
                        working = false
                        if model.errorMessage == nil { passphrase = ""; dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folder == nil || passphrase.isEmpty || working || model.phase != .unlocked)
            }
            if let e = model.errorMessage { Text(e).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Vault"
        if panel.runModal() == .OK { folder = panel.url }
    }
}
#endif
