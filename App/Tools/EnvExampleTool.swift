import SwiftUI
import ToolKit
import VaultCore
import EnvKit

struct EnvExampleTool: Tool {
    let id = "env-example"
    let title = ".env.example"
    let subtitle = "Generate a committable .env.example from a real env file: same keys and comments, secrets blanked."
    let systemImage = "doc.badge.gearshape"
    let category = ToolCategory.env

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(EnvExampleView(context: context)) }
}

private struct EnvExampleView: View {
    let context: ToolContext
    @State private var projects: [Project] = []
    @State private var items: [UUID: [Item]] = [:]
    @State private var source: Item?
    @State private var placeholders = true

    private var output: String {
        guard let s = source else { return "" }
        return EnvHygiene.example(from: DotEnv.parse(s.payload.primaryText), placeholders: placeholders)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Env file", selection: $source) {
                    Text("Choose…").tag(Item?.none)
                    ForEach(projects) { p in
                        ForEach((items[p.id] ?? []).filter { $0.kind == .envFile }) { i in
                            Text("\(p.name) › \(i.name)").tag(Item?.some(i))
                        }
                    }
                }
                Toggle("Keep non-secret values (ports, booleans, localhost)", isOn: $placeholders).toggleStyle(.checkbox)
            }
            if source != nil {
                ScrollView {
                    Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 200)
                HStack {
                    Button { context.copyToClipboard(output, false) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { save() } label: { Label("Save as .env.example…", systemImage: "square.and.arrow.down") }
                }
            } else {
                ContentUnavailableView("Pick an env file", systemImage: "doc.badge.gearshape")
            }
        }
        .padding(16)
        .task {
            projects = await context.projects()
            for p in projects { items[p.id] = await context.items(p.id) }
        }
    }

    private func save() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Write Here"; panel.message = "Choose the project folder; .env.example will be written into it."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        try? output.write(to: dir.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
    }
}
