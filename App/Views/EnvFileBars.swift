import SwiftUI
import VaultCore
import EnvKit

// MARK: - Lint

/// "3 issues" strip under an env file, expandable to the list.
struct LintBar: View {
    let issues: [EnvLint.Issue]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                Label("\(issues.count) issue\(issues.count == 1 ? "" : "s")", systemImage: expanded ? "chevron.down" : "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            if expanded {
                ForEach(issues) { i in
                    Text("Line \(i.line + 1): \(i.message)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.06))
    }
}

// MARK: - Compare with sibling files

/// How this file's keys differ from the other env files in the project, e.g.
/// ".env.production +1 −2". Click one for the key-by-key comparison.
struct CompareBar: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let doc: EnvDocument
    @State private var comparing: Item?

    struct Difference: Identifiable {
        var id: UUID { other.id }
        let other: Item
        let onlyHere: [String]
        let missingHere: [String]
    }

    private var differences: [Difference] {
        let mine = Set(doc.values.keys)
        return model.items(in: item.projectId)
            .filter { $0.id != item.id && $0.kind == .envFile }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { other in
                let theirs = Set(DotEnv.parse(other.payload.primaryText).values.keys)
                let onlyHere = mine.subtracting(theirs).sorted(), missing = theirs.subtracting(mine).sorted()
                // A template only matters for keys it has that this file lacks.
                if EnvDiscovery.isTemplate(other.name) { return missing.isEmpty ? nil : Difference(other: other, onlyHere: [], missingHere: missing) }
                return onlyHere.isEmpty && missing.isEmpty ? nil : Difference(other: other, onlyHere: onlyHere, missingHere: missing)
            }
    }

    var body: some View {
        let diffs = differences
        if !diffs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label("Keys differ from", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary)
                    ForEach(diffs) { d in
                        Button { comparing = d.other } label: {
                            HStack(spacing: 4) {
                                Text(d.other.name).font(.caption.monospaced())
                                if !d.onlyHere.isEmpty { Text("+\(d.onlyHere.count)").foregroundStyle(.green) }
                                if !d.missingHere.isEmpty { Text("−\(d.missingHere.count)").foregroundStyle(.red) }
                            }
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(d.missingHere.count) key(s) in \(d.other.name) are missing here; \(d.onlyHere.count) key(s) here are not in it.")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
            .sheet(item: $comparing) { other in CompareSheet(item: item, other: other) }
        }
    }
}

/// Keys only in one file or with different values; values are never shown.
struct CompareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: Item
    let other: Item

    var body: some View {
        let mine = DotEnv.parse(item.payload.primaryText)
        let theirs = DotEnv.parse(other.payload.primaryText)
        let changes = EnvDiff.diff(theirs, mine)
        let missing = changes.compactMap { if case .removed(let k, _) = $0 { k } else { nil } }
        let extra = changes.compactMap { if case .added(let k, _) = $0 { k } else { nil } }
        let differ = changes.compactMap { if case .changed(let k, _, _) = $0 { k } else { nil } }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(item.name) compared with \(other.name)").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("Missing here (in \(other.name) only)", missing, color: .red)
                    group("Only in \(item.name)", extra, color: .green)
                    if !EnvDiscovery.isTemplate(other.name) { group("Different values", differ, color: .orange) }
                    if changes.isEmpty { Text("Same keys and values.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                if !missing.isEmpty {
                    Button("Add \(missing.count) Missing Key\(missing.count == 1 ? "" : "s") (Empty)") {
                        var doc = mine
                        for k in missing { doc = doc.setting(k, to: "") }
                        Task { await model.updateItem(item.id, payload: .envFile(text: doc.text)) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
    }

    @ViewBuilder
    private func group(_ title: String, _ keys: [String], color: Color) -> some View {
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(keys, id: \.self) { k in
                    Text(k).font(.callout.monospaced()).foregroundStyle(color)
                }
            }
        }
    }
}

// MARK: - Folder sync

/// The folders this item is kept written into, with status and conflict handling.
struct FileLinksBar: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        let links = model.fileLinks.links(for: item.id)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(links) { link in row(link) }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.05))
            .task(id: item.revisionId) { model.fileLinks.syncItem(item.id) }
        }
    }

    @ViewBuilder
    private func row(_ link: FileLink) -> some View {
        let status = model.fileLinks.status[link.id]
        HStack(spacing: 8) {
            Image(systemName: icon(status)).foregroundStyle(color(status))
            Text(abbreviated(link.filePath)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(caption(status, link)).font(.caption).foregroundStyle(color(status) == .secondary ? .secondary : color(status))
            Spacer()
            if needsChoice(status) {
                Button("Use EnVault’s Version") { model.fileLinks.overwrite(link.id) }
                    .help("Write EnVault’s version to the file")
                Button("Use the File’s Version") { model.fileLinks.useFileVersion(link.id) }
                    .help("Save the file as a new revision (History keeps the current one)")
            }
            Menu {
                Toggle("Save Edits Made in the File to EnVault", isOn: Binding(get: { link.importEdits }, set: { model.fileLinks.setImportEdits(link.id, $0) }))
                Toggle("Remove the File While EnVault Is Locked", isOn: Binding(get: { link.removeWhenLocked }, set: { model.fileLinks.setRemoveWhenLocked(link.id, $0) }))
                Button("Check Now") { model.fileLinks.syncItem(item.id) }
                Divider()
                Button("Stop Syncing (Keep File)") { model.fileLinks.remove(link.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
    }

    private func needsChoice(_ s: FileLinkStatus?) -> Bool {
        switch s {
        case .changedOnDisk, .conflict: true
        default: false
        }
    }

    private func icon(_ s: FileLinkStatus?) -> String {
        switch s {
        case .changedOnDisk, .conflict: "exclamationmark.triangle.fill"
        case .failed, .itemDeleted: "xmark.octagon"
        case .removedWhileLocked: "lock"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func color(_ s: FileLinkStatus?) -> Color {
        switch s {
        case .changedOnDisk, .conflict: .orange
        case .failed, .itemDeleted: .red
        default: .secondary
        }
    }

    private func caption(_ s: FileLinkStatus?, _ link: FileLink) -> String {
        switch s {
        case .synced(let d?):
            switch link.lastChange {
            case .fromFile: "file edit saved \(d.formatted(.relative(presentation: .named)))"
            case .merged: "merged \(d.formatted(.relative(presentation: .named)))"
            default: "synced \(d.formatted(.relative(presentation: .named)))"
            }
        case .synced(nil), nil: "kept in sync"
        case .changedOnDisk: "edited in the file"
        case .conflict(let keys) where keys.isEmpty: "the file and EnVault differ"
        case .conflict(let keys): "changed in both places: \(keys.joined(separator: ", "))"
        case .removedWhileLocked: "removed while locked"
        case .itemDeleted: "item deleted"
        case .failed(let e): e
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = CLIService.realHome.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
