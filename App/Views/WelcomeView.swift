import SwiftUI
import VaultSync
import VaultCore

/// First launch: create a new vault folder or open an existing one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var chosenURL: URL?
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("eVault").font(.largeTitle.bold())
            Text("Encrypted .env and secret storage that syncs through any folder.\nYour passphrase never leaves this Mac; only ciphertext is ever written.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            if creating {
                createForm
            } else {
                HStack(spacing: 12) {
                    Button { pickFolder(create: true) } label: {
                        Label("Create New Vault…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { pickFolder(create: false) } label: {
                        Label("Open Existing Vault…", systemImage: "folder")
                    }
                }
                if SyncLocations.iCloudDriveRoot != nil {
                    Label("iCloud Drive is available. Put the vault there to sync it to your other Macs.", systemImage: "icloud")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let e = model.errorMessage {
                Text(e).foregroundStyle(.red).font(.callout).frame(maxWidth: 440)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Folder") {
                Text(chosenURL?.path(percentEncoded: false) ?? "").font(.callout).textSelection(.enabled)
            }
            SecureField("Passphrase", text: $passphrase)
            SecureField("Confirm passphrase", text: $confirm)
            Text("There is no reset. If you forget the passphrase the vault is unrecoverable. Use a long one and keep it in a password manager.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { creating = false; passphrase = ""; confirm = "" }
                Spacer()
                Button("Create Vault") {
                    guard let url = chosenURL else { return }
                    busy = true
                    Task {
                        await model.createVault(at: url, passphrase: passphrase)
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(passphrase.count < 8 || passphrase != confirm || busy)
            }
        }
        .frame(width: 440)
        .textFieldStyle(.roundedBorder)
    }

    private func pickFolder(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SyncLocations.iCloudDriveRoot
        panel.prompt = create ? "Use Folder" : "Open Vault"
        panel.message = create
            ? "Choose an empty folder for the vault. Inside iCloud Drive is recommended; name it \"eVault\"."
            : "Choose a folder that contains a vault.json created by eVault."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if create {
            chosenURL = url
            creating = true
            model.errorMessage = nil
        } else {
            Task { await model.openVault(at: url) }
        }
    }
}
