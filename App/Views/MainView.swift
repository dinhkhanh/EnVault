import SwiftUI
import VaultCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseManager.self) private var licenses
    @State private var showNewProject = false
    @State private var showNewItem = false
    @State private var showImportProjects = false
    @State private var showNewTeamVault = false

    var body: some View {
        @Bindable var model = model
        Group {
            if let tool = model.selectedToolId.flatMap({ model.tools.tool(id: $0) }) {
                // Tools get the whole width: sidebar + tool.
                NavigationSplitView {
                    SidebarView(showNewProject: $showNewProject)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                } detail: {
                    ToolHostView(tool: tool)
                        .id(tool.id)
                }
            } else if let project = model.selectedProject {
                NavigationSplitView {
                    SidebarView(showNewProject: $showNewProject)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                } content: {
                    ItemListView(project: project, showNewItem: $showNewItem)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    if let item = model.selectedItem {
                        ItemDetailView(item: item)
                            .id(item.id)
                    } else {
                        ContentUnavailableView("Nothing Selected", systemImage: "doc.text", description: Text("Select an item, or drop a .env file onto the list."))
                    }
                }
            } else {
                // No project selected: sidebar + one pane, so the empty state has room.
                NavigationSplitView {
                    SidebarView(showNewProject: $showNewProject)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                } detail: {
                    noProject
                }
            }
        }
        .sheet(isPresented: $showNewProject) { NewProjectSheet() }
        .sheet(isPresented: $showImportProjects) { ImportProjectsSheet() }
        .sheet(item: Binding(get: { model.pendingVaultImport }, set: { if $0 == nil { model.pendingVaultImport = nil } })) { VaultImportSheet(pending: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .importProjects)) { _ in showImportProjects = true }
        .sheet(isPresented: $showNewTeamVault) { NewTeamVaultSheet() }
        .sheet(isPresented: $model.shareNeedsIdentity) { JoinIdentitySheet() }
        .onReceive(NotificationCenter.default.publisher(for: .newTeamVault)) { _ in
            if TeamFeatures.enabled, licenses.require(.teamSharing) { showNewTeamVault = true }
        }
        .sheet(isPresented: $showNewItem) {
            if let pid = model.selectedProjectId { NewItemSheet(projectId: pid) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in if licenses.canAddProject(existing: model.projectsTowardLimit) { showNewProject = true } }
        .onReceive(NotificationCenter.default.publisher(for: .newItem)) { _ in if model.selectedProjectId != nil { showNewItem = true } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let e = model.errorMessage {
                    Button { model.errorMessage = nil } label: { Label(e, systemImage: "exclamationmark.triangle.fill") }
                        .labelStyle(.titleAndIcon).foregroundStyle(.red).help(e)
                }
                Button { Task { await model.refreshFromDisk() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Re-read the vault folder (changes from other Macs arrive automatically)")
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
                    .help("Lock the vault (⇧⌘L)")
            }
        }
    }

    @ViewBuilder private var noProject: some View {
        if model.projects.isEmpty {
            ContentUnavailableView {
                Label("Bring In Your .env Files", systemImage: "square.and.arrow.down.on.square")
            } description: {
                Text("Point EnVault at the folder that holds your projects. It finds the .env files in each one and imports them, one project per folder.")
            } actions: {
                Button("Import Projects from Folder…") { showImportProjects = true }.buttonStyle(.borderedProminent)
                Button("New Empty Project") { if licenses.canAddProject(existing: model.projectsTowardLimit) { showNewProject = true } }
            }
        } else {
            ContentUnavailableView("No Project", systemImage: "folder", description: Text("Select a project in the sidebar, or create one to start storing env files."))
        }
    }
}
