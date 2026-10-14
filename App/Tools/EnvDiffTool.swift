import SwiftUI
import ToolKit
import VaultCore
import EnvKit

struct EnvDiffTool: Tool {
    let id = "env-diff"
    let title = "Env Diff"
    let subtitle = "Compare the keys of two env files, e.g. .env.local vs .env.production, or against a pasted .env.example."
    let systemImage = "arrow.left.arrow.right"
    let category = ToolCategory.env

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(EnvDiffView(context: context)) }
}

private struct EnvDiffView: View {
    let context: ToolContext
    @State private var projects: [Project] = []
    @State private var items: [UUID: [Item]] = [:]
    @State private var left: Item?
    @State private var right: Item?
    @State private var pasted = ""
    @State private var usePasted = false

    private var envItems: [Item] { items.values.flatMap { $0 }.filter { $0.kind == .envFile } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                picker("From", selection: $left)
                Image(systemName: "arrow.right")
                if usePasted {
                    Text("Pasted text").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    picker("To", selection: $right)
                }
                Toggle("Paste instead", isOn: $usePasted).toggleStyle(.checkbox)
            }
            if usePasted {
                TextEditor(text: $pasted).font(.system(.body, design: .monospaced)).frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            if let l = left, let rightDoc {
                let changes = EnvDiff.diff(DotEnv.parse(l.payload.primaryText), rightDoc)
                ScrollView { DiffList(changes: changes, fromLabel: l.name, toLabel: usePasted ? "pasted" : (right?.name ?? "")) }
            } else {
                ContentUnavailableView("Pick two env files", systemImage: "arrow.left.arrow.right")
            }
        }
        .padding(16)
        .task {
            projects = await context.projects()
            for p in projects { items[p.id] = await context.items(p.id) }
        }
    }

    private var rightDoc: EnvDocument? {
        if usePasted { return DotEnv.parse(pasted) }
        return right.map { DotEnv.parse($0.payload.primaryText) }
    }

    private func picker(_ label: String, selection: Binding<Item?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose…").tag(Item?.none)
            ForEach(projects) { p in
                ForEach((items[p.id] ?? []).filter { $0.kind == .envFile }) { i in
                    Text("\(p.name) › \(i.name)").tag(Item?.some(i))
                }
            }
        }
    }
}
