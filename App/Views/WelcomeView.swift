import SwiftUI
import VaultSync
import VaultCore

/// First launch: create a new vault (in iCloud or a folder) or open an existing one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    enum Flow: Equatable { case menu, createFolder(URL), createICloud, openICloud }
    @State private var flow: Flow = .menu
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var cloudVaults: [AppModel.CloudVaultSummary] = []
    @State private var loadingVaults = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("eVault").font(.largeTitle.bold())
            Text("Encrypted .env and secret storage for all your Macs.\nYour passphrase never leaves this Mac; only ciphertext is ever synced.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)

            switch flow {
            case .menu: menu
            case .createFolder(let url): createForm(folder: url)
            case .createICloud: createForm(folder: nil)
            case .openICloud: openICloudList
            }

            if let e = model.errorMessage {
                Text(e).foregroundStyle(.red).font(.callout).frame(maxWidth: 440)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var menu: some View {
        VStack(spacing: 14) {
            if model.cloudAvailable {
                HStack(spacing: 12) {
                    Button { model.errorMessage = nil; flow = .createICloud } label: {
                        Label("Create Vault in iCloud…", systemImage: "icloud.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.errorMessage = nil; flow = .openICloud; loadVaults() } label: {
                        Label("Open Vault from iCloud…", systemImage: "icloud.and.arrow.down")
                    }
                }
                Text("Synced through your iCloud account with CloudKit. Other Macs signed in to the same account see it automatically.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                Divider().frame(width: 200)
            }
            HStack(spacing: 12) {
                if model.cloudAvailable {
                    Button { pickFolder(create: true) } label: { Label("Create in a Folder…", systemImage: "plus.circle") }
                } else {
                    Button { pickFolder(create: true) } label: { Label("Create New Vault…", systemImage: "plus.circle") }
                        .buttonStyle(.borderedProminent)
                }
                Button { pickFolder(create: false) } label: {
                    Label(model.cloudAvailable ? "Open from a Folder…" : "Open Existing Vault…", systemImage: "folder")
                }
            }
            if !model.cloudAvailable, SyncLocations.iCloudDriveRoot != nil {
                Label("iCloud Drive is available. Put the vault there to sync it to your other Macs.", systemImage: "icloud")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func createForm(folder: URL?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let folder {
                LabeledContent("Folder") {
                    Text(folder.path(percentEncoded: false)).font(.callout).textSelection(.enabled)
                }
            } else {
                Label("New vault in iCloud", systemImage: "icloud").font(.headline)
            }
            SecureField("Passphrase", text: $passphrase)
            SecureField("Confirm passphrase", text: $confirm)
            Text("There is no reset. If you forget the passphrase the vault is unrecoverable. Use a long one and keep it in a password manager.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { flow = .menu; passphrase = ""; confirm = "" }
                Spacer()
                Button("Create Vault") {
                    busy = true
                    let pw = passphrase
                    Task {
                        if let folder { await model.createVault(at: folder, passphrase: pw, mode: .folder) }
                        else { await model.createVaultInICloud(passphrase: pw) }
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

    private var openICloudList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Vaults in your iCloud account", systemImage: "icloud").font(.headline)
            if loadingVaults {
                ProgressView().frame(maxWidth: .infinity)
            } else if cloudVaults.isEmpty {
                Text("No vaults found. Create one on this Mac, or check that iCloud is signed in with the same account as your other Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(cloudVaults) { v in
                    Button {
                        busy = true
                        Task { await model.openICloudVault(v.id); busy = false }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Vault \(v.id.uuidString.prefix(8))").font(.body.monospaced())
                                if let c = v.createdAt { Text("created \(c, format: .dateTime.day().month().year())").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
            }
            HStack {
                Button("Back") { flow = .menu }
                Spacer()
                Button("Refresh") { loadVaults() }.disabled(loadingVaults)
            }
        }
        .frame(width: 440)
    }

    private func loadVaults() {
        loadingVaults = true
        Task {
            cloudVaults = await model.listICloudVaults()
            loadingVaults = false
        }
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
        model.errorMessage = nil
        if create {
            flow = .createFolder(url)
        } else {
            Task { await model.openVault(at: url, mode: .folder) }
        }
    }
}
