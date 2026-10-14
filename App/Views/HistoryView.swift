import SwiftUI
import VaultCore
import EnvKit

/// Revision history of one item with a diff against the current version.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var revisions: [ItemRevision] = []
    @State private var selected: ItemRevision?
    @State private var confirmCompact = false

    var body: some View {
        NavigationSplitView {
            List(revisions, selection: $selected) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.modifiedAt, format: .dateTime.day().month().hour().minute())
                        if r.id == item.revisionId { Text("current").font(.caption).padding(.horizontal, 5).background(.tint.opacity(0.2), in: Capsule()) }
                        if r.deleted { Text("deleted").font(.caption).foregroundStyle(.red) }
                    }
                    Text(r.device.name).font(.caption).foregroundStyle(.secondary)
                }
                .tag(r)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let r = selected {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(r.name).font(.headline)
                        Spacer()
                        if r.id != item.revisionId {
                            Button("Restore This Version") { Task { await model.restore(r); dismiss() } }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    Divider()
                    if case .envFile(let old) = r.payload, case .envFile(let cur) = item.payload {
                        DiffList(changes: EnvDiff.diff(DotEnv.parse(old), DotEnv.parse(cur)), fromLabel: "this version", toLabel: "current")
                        Divider()
                    }
                    ScrollView {
                        Text(r.payload.primaryText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                ContentUnavailableView("Select a revision", systemImage: "clock")
            }
        }
        .frame(width: 820, height: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem {
                Button("Compact…") { confirmCompact = true }.disabled(revisions.count < 2)
                    .help("Delete all older revisions from the vault folder")
            }
        }
        .confirmationDialog("Delete \(revisions.count - 1) older revision(s)?", isPresented: $confirmCompact) {
            Button("Compact", role: .destructive) { Task { await model.compact(itemId: item.id); await load() } }
        } message: { Text("Only the current version is kept. Other Macs will drop the old revisions after sync.") }
        .task { await load() }
    }

    private func load() async {
        revisions = await model.history(of: item.id)
        selected = revisions.first
    }
}

struct DiffList: View {
    let changes: [EnvChange]
    let fromLabel: String
    let toLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if changes.isEmpty {
                Text("Same keys and values as \(toLabel).").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Changes from \(fromLabel) to \(toLabel)").font(.caption).foregroundStyle(.secondary)
                ForEach(changes) { c in
                    HStack(alignment: .top, spacing: 6) {
                        switch c {
                        case .added(let k, let v):
                            Text("+").foregroundStyle(.green); Text(k).bold(); Text(v).foregroundStyle(.secondary)
                        case .removed(let k, let v):
                            Text("−").foregroundStyle(.red); Text(k).bold(); Text(v).foregroundStyle(.secondary)
                        case .changed(let k, let o, let n):
                            Text("~").foregroundStyle(.orange); Text(k).bold(); Text(o).strikethrough().foregroundStyle(.secondary); Text("→"); Text(n)
                        }
                    }
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
