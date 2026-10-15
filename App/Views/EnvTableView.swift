import SwiftUI
import EnvKit

/// Structured view of a dotenv document: one row per line, values masked,
/// per-row copy/reveal/edit. Comments and blank lines are shown dimmed so the
/// user still sees the file's shape.
struct EnvTableView: View {
    let doc: EnvDocument
    let masked: Bool
    var keyAges: [String: Date] = [:]
    let onEdit: (String, String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(doc.lines) { line in
                    switch line.kind {
                    case .entry(let e):
                        EnvEntryRow(entry: e, masked: masked, lastChanged: keyAges[e.key], onEdit: onEdit, onDelete: onDelete)
                    case .comment(let c):
                        Text("# " + c).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 3)
                    case .blank:
                        Color.clear.frame(height: 10)
                    case .invalid(let reason):
                        Label("\(line.raw)  — \(reason)", systemImage: "exclamationmark.triangle")
                            .font(.system(.callout, design: .monospaced)).foregroundStyle(.orange)
                            .padding(.horizontal, 16).padding(.vertical, 3)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .overlay {
            if doc.entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "doc", description: Text("No KEY=value lines yet. Use “Add Key” or edit the raw text."))
            }
        }
    }
}

struct EnvEntryRow: View {
    let entry: EnvEntry
    let masked: Bool
    var lastChanged: Date?
    let onEdit: (String, String) -> Void
    let onDelete: (String) -> Void
    @State private var revealed = false
    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var hovering = false

    private var shown: String {
        if editing { return draft }
        if masked && !revealed { return String(repeating: "•", count: min(max(entry.value.count, 6), 24)) }
        return entry.value
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.key)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
                .frame(minWidth: 160, alignment: .leading)
                .lineLimit(1)
            if editing {
                TextField("", text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
            } else {
                Text(shown)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(entry.value.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c = entry.inlineComment, !editing {
                Text("# " + c).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let d = lastChanged, !editing, !entry.value.isEmpty {
                let days = Int(Date().timeIntervalSince(d) / 86400)
                if days >= 90 {
                    Label("\(days)d", systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Value unchanged for \(days) days. Consider rotating it.")
                }
            }
            HStack(spacing: 4) {
                if editing {
                    Button("Save", action: commit).controlSize(.small)
                } else {
                    Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                        .help(revealed ? "Hide" : "Reveal").disabled(!masked)
                    Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help("Copy value")
                    Button { draft = entry.value; editing = true } label: { Image(systemName: "pencil") }
                        .help("Edit value")
                    Button { onDelete(entry.key) } label: { Image(systemName: "trash") }
                        .help("Remove line")
                }
            }
            .buttonStyle(.borderless)
            .opacity(hovering || editing ? 1 : 0.35)
            .autoMask($revealed)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Value") { copy() }
            Button("Copy KEY=value") { ClipboardService.shared.copy("\(entry.key)=\(entry.value)") }
            Button("Copy Key") { ClipboardService.shared.copy(entry.key, concealed: false) }
        }
    }

    private func copy() {
        ClipboardService.shared.copy(entry.value)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
    }

    private func commit() {
        editing = false
        if draft != entry.value { onEdit(entry.key, draft) }
    }
}
