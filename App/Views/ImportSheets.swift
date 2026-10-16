import SwiftUI
import EnvKit
import LicenseKit

/// "Import Projects from Folder…": pick a workspace (say ~/Projects), see every
/// project folder with .env files in it, import the ones you tick. One EnVault
/// project per folder; templates like .env.example are left out.
struct ImportProjectsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseManager.self) private var licenses
    @Environment(\.dismiss) private var dismiss

    @State private var root: URL?
    @State private var found: [EnvDiscovery.FoundProject] = []
    @State private var selected: Set<String> = []
    @State private var scanning = false
    @State private var result: String?

    private var existingNames: Set<String> { Set(model.projects.map(\.name)) }
    /// New projects a Free plan can still create.
    private var newProjectRoom: Int? {
        licenses.allows(.unlimitedProjects) ? nil : max(0, Entitlements.freeProjectLimit - model.projects.count)
    }
    private var selectedNew: Int { selected.filter { !existingNames.contains($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Projects from a Folder").font(.headline)
            Text("Choose the folder that holds your projects. EnVault finds the .env files in each project folder (templates like .env.example are skipped) and imports them as one project per folder.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(root == nil ? "Choose Folder…" : "Choose Another…") { pick() }
                if let root { Text(root.path(percentEncoded: false)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
            }
            if !found.isEmpty {
                HStack {
                    Text("\(found.count) project\(found.count == 1 ? "" : "s"), \(found.reduce(0) { $0 + $1.files.count }) env files").font(.callout)
                    Spacer()
                    Button("Select All") { selectAll() }.buttonStyle(.borderless)
                    Button("None") { selected = [] }.buttonStyle(.borderless)
                }
                List(found) { p in
                    Toggle(isOn: binding(for: p)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).bold()
                                if existingNames.contains(p.name) { Text("adds to existing project").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(p.files.map(\.itemName).joined(separator: "  ·  ")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!selected.contains(p.name) && !canSelect(p))
                }
                .frame(minHeight: 240)
                if let room = newProjectRoom {
                    HStack {
                        Text("The free plan holds \(Entitlements.freeProjectLimit) projects; \(room) new one\(room == 1 ? "" : "s") can be added.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Get Pro") { licenses.upgradePrompt = .unlimitedProjects }.buttonStyle(.link)
                    }
                }
            } else if root != nil && !scanning {
                Text("No .env files found within four levels of that folder.").foregroundStyle(.secondary)
            }
            if let result { Label(result, systemImage: "checkmark.circle").foregroundStyle(.green) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("Import") { Task { await runImport() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || scanning)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear { root?.stopAccessingSecurityScopedResource() }
    }

    private func canSelect(_ p: EnvDiscovery.FoundProject) -> Bool {
        if existingNames.contains(p.name) { return true }
        guard let room = newProjectRoom else { return true }
        return selectedNew < room
    }

    private func binding(for p: EnvDiscovery.FoundProject) -> Binding<Bool> {
        Binding(get: { selected.contains(p.name) }, set: { on in if on { selected.insert(p.name) } else { selected.remove(p.name) } })
    }

    private func selectAll() {
        selected = []
        for p in found where canSelect(p) { selected.insert(p.name) }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "Choose the folder that contains your projects, e.g. ~/Projects or ~/code."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        root = url
        found = []; selected = []; result = nil
        scanning = true
        Task.detached {
            let projects = EnvDiscovery.discover(in: url)
            await MainActor.run {
                found = projects
                scanning = false
                selectAll()
            }
        }
    }

    private func runImport() async {
        guard let root else { return }
        let chosen = found.filter { selected.contains($0.name) }
        let r = await model.importDiscovered(chosen, root: root)
        result = "Imported \(r.files) file\(r.files == 1 ? "" : "s") into \(chosen.count) project\(chosen.count == 1 ? "" : "s") (\(r.projects) new)."
    }
}

/// Asks for the DOTENV_KEY(s) of a dropped `.env.vault` file.
struct VaultImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingVaultImport
    @State private var keys = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(pending.fileName)").font(.headline)
            Text("This file is encrypted by dotenv-vault. Paste the DOTENV_KEY for each environment you want (one per line). Environments in the file: \(pending.environments.joined(separator: ", ")).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $keys)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Each environment becomes an item named .env.<environment>.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { model.pendingVaultImport = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task {
                        error = await model.completeVaultImport(keys: keys)
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(keys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}
