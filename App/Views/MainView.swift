import SwiftUI
import VaultCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false
    @State private var showNewItem = false

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
            } else {
                NavigationSplitView {
                    SidebarView(showNewProject: $showNewProject)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
                } content: {
                    if let project = model.selectedProject {
                        ItemListView(project: project, showNewItem: $showNewItem)
                            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    } else {
                        ContentUnavailableView("No Project", systemImage: "folder", description: Text("Create a project to start storing env files."))
                    }
                } detail: {
                    if let item = model.selectedItem {
                        ItemDetailView(item: item)
                            .id(item.id)
                    } else {
                        ContentUnavailableView("Nothing Selected", systemImage: "doc.text", description: Text("Select an item, or drop a .env file onto the list."))
                    }
                }
            }
        }
        .sheet(isPresented: $showNewProject) { NewProjectSheet() }
        .sheet(isPresented: $showNewItem) {
            if let pid = model.selectedProjectId { NewItemSheet(projectId: pid) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in showNewProject = true }
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
}
