import SwiftUI
import VaultCore
import UniformTypeIdentifiers

struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var showNewItem: Bool
    @State private var filter = ""
    @State private var deleting: Item?
    @State private var renaming: Item?

    private var items: [Item] {
        let all = model.items(in: project.id)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.tags.contains { $0.localizedCaseInsensitiveContains(filter) } }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedItemId) {
            ForEach(items) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Rename…") { renaming = item }
                        Menu("Move to") {
                            ForEach(model.projects.filter { $0.id != project.id }) { p in
                                Button(p.name) { Task { await model.updateItem(item.id, projectId: p.id) } }
                            }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = item }
                    }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Items", systemImage: "doc.text")
                } description: {
                    Text("Drop .env files here, or press ⌘N.")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(urls, into: project.id) }
            return true
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup {
                Button { showNewItem = true } label: { Label("New Item", systemImage: "plus") }.help("New item (⌘N)")
                Menu {
                    Button("Import Files…") { importFiles() }
                        .help(".env, JSON (Doppler, 1Password item) or .env.vault")
                    Button("Scan Folder for .env Files…") { importFolder() }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
            }
        }
        .sheet(item: $renaming) { item in RenameSheet(title: "Rename Item", name: item.name) { newName in Task { await model.updateItem(item.id, name: newName) } } }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button("Delete", role: .destructive) { Task { await model.deleteItem(item.id) } }
        } message: { _ in
            Text("It can be restored from history until the item is compacted.")
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = "Choose files to import into \(project.name): .env files, JSON exports (Doppler, 1Password, vercel) or a .env.vault."
        guard panel.runModal() == .OK else { return }
        Task { await model.importFiles(panel.urls, into: project.id) }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a project folder. EnVault imports every .env* file in it (two levels deep, skipping node_modules etc.)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let urls = AppModel.findEnvFiles(in: dir)
        Task { await model.importFiles(urls, into: project.id) }
    }
}

struct ItemRow: View {
    let item: Item
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text("\(Text(item.modifiedAt, style: .relative)) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
    private var icon: String {
        switch item.kind {
        case .envFile: "doc.text"
        case .secret: "key"
        case .note: "note.text"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

struct NewItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID
    @State private var kind: ItemKind = .envFile
    @State private var name = ".env.local"
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Item").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(ItemKind.known, id: \.self) { Text($0.description).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, k in
                name = switch k { case .envFile: ".env.local"; case .secret: "API_KEY"; default: "Notes" }
            }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text(hint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }

    private var hint: String {
        switch kind {
        case .envFile: "Paste the contents of the .env file. Comments and ordering are preserved exactly."
        case .secret: "Paste the secret value."
        default: "Markdown notes."
        }
    }

    private func create() {
        let payload: ItemPayload = switch kind {
        case .envFile: .envFile(text: text)
        case .secret: .secret(value: text.trimmingCharacters(in: .whitespacesAndNewlines), notes: "")
        default: .note(markdown: text)
        }
        Task { await model.createItem(in: projectId, name: name.trimmingCharacters(in: .whitespaces), payload: payload) }
        dismiss()
    }
}
