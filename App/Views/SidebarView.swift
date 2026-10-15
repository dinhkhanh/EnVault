import SwiftUI
import VaultCore
import ToolKit

enum SidebarSelection: Hashable {
    case project(UUID)
    case tool(String)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseManager.self) private var licenses
    @Binding var showNewProject: Bool
    @State private var renaming: Project?
    @State private var deleting: Project?

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if let t = model.selectedToolId { return .tool(t) }
                if let p = model.selectedProjectId { return .project(p) }
                return nil
            },
            set: { sel in
                switch sel {
                case .project(let id): model.selectedToolId = nil; model.selectedProjectId = id; model.selectedItemId = nil
                case .tool(let id): if licenses.require(.developerTools) { model.selectedToolId = id }
                case nil: break
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section("Projects") {
                ForEach(model.projects) { p in
                    ProjectRow(project: p, onRename: { renaming = p }, onDelete: { deleting = p })
                        .tag(SidebarSelection.project(p.id))
                }
            }
            ForEach(model.tools.byCategory, id: \.0) { category, tools in
                Section(category.rawValue) {
                    ForEach(tools, id: \.id) { t in
                        HStack {
                            Label(t.title, systemImage: t.systemImage)
                            if !licenses.allows(.developerTools) {
                                Spacer()
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(SidebarSelection.tool(t.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { if licenses.canAddProject(existing: model.projects.count) { showNewProject = true } } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                if model.syncMode == .iCloud {
                    SyncStatusLabel()
                } else if model.isInICloudDrive {
                    Image(systemName: "icloud").foregroundStyle(.secondary).help("Vault is in iCloud Drive")
                }
            }
            .padding(8)
            .background(.bar)
        }
        .sheet(item: $renaming) { p in RenameSheet(title: "Rename Project", name: p.name) { newName in Task { await model.renameProject(p.id, name: newName) } } }
        .confirmationDialog("Delete “\(deleting?.name ?? "")” and all its items?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { p in
            Button("Delete", role: .destructive) { Task { await model.deleteProject(p.id) } }
        } message: { _ in
            Text("Items are tombstoned, not erased; their history stays in the vault until compacted.")
        }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Label(project.name, systemImage: "folder")
            Spacer()
            Text(String(project.itemCount)).foregroundStyle(.secondary).font(.caption)
        }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Delete Project…", role: .destructive, action: onDelete)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(urls, into: project.id) }
            return true
        }
    }
}

struct RenameSheet: View {
    let title: String
    @State var name: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n); dismiss()
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project").font(.headline)
            TextField("Name (e.g. my-saas)", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { await model.createProject(name: n) }
        dismiss()
    }
}

/// Small iCloud sync indicator used in the sidebar footer and lock screen.
struct SyncStatusLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { Task { await model.syncNow() } } label: {
            switch model.syncStatus {
            case .syncing:
                if #available(macOS 15, *) {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud").symbolEffect(.rotate, isActive: true)
                } else {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud").symbolEffect(.pulse, isActive: true)
                }
            case .error(let e):
                Label("Sync error", systemImage: "exclamationmark.icloud").foregroundStyle(.red).help(e)
            case .idle:
                if let t = model.lastCloudSync {
                    Label("Synced \(Text(t, style: .relative)) ago", systemImage: "checkmark.icloud")
                } else {
                    Label("iCloud", systemImage: "icloud")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Sync with iCloud now")
    }
}
