import SwiftUI
import VaultCore
import EnvKit

struct ItemDetailView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @State private var showHistory = false
    @State private var tagsText = ""
    @State private var editingTags = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch item.payload {
            case .envFile(let text):
                EnvFileView(item: item, text: text)
            case .secret(let value, let notes):
                SecretView(item: item, value: value, notes: notes)
            case .note(let md):
                NoteView(item: item, markdown: md)
            case .unknown(let kind, _):
                ContentUnavailableView("Unsupported item", systemImage: "questionmark.square.dashed", description: Text("This “\(kind)” item was created by a newer eVault. Its data is preserved."))
            }
        }
        .navigationTitle(item.name)
        .navigationSubtitle(model.selectedProject?.name ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("\(item.revisionCount) revision\(item.revisionCount == 1 ? "" : "s")")
            }
        }
        .sheet(isPresented: $showHistory) { HistoryView(item: item) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edited \(Text(item.modifiedAt, style: .relative)) ago on \(item.modifiedBy.name)")
                Text("\(item.revisionCount) revision\(item.revisionCount == 1 ? "" : "s") · created \(item.createdAt, format: .dateTime.day().month().year())")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if editingTags {
                TextField("tags, comma separated", text: $tagsText)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit(saveTags)
                Button("Save", action: saveTags).controlSize(.small)
            } else {
                ForEach(item.tags, id: \.self) { t in
                    Text(t).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Button { tagsText = item.tags.joined(separator: ", "); editingTags = true } label: { Image(systemName: "tag") }
                    .buttonStyle(.borderless).help("Edit tags")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func saveTags() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { await model.updateItem(item.id, tags: tags) }
        editingTags = false
    }
}

// MARK: - Env file

struct EnvFileView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.maskValues) private var maskValues = true
    let item: Item
    let text: String

    enum Mode: String, CaseIterable { case table = "Keys", raw = "Raw" }
    @State private var mode: Mode = .table
    @State private var draft: String
    @State private var exportConfirm: URL?
    @State private var keyAges: [String: Date] = [:]
    /// Temporary, per-editor override of the "Mask values by default" setting;
    /// never written back to it. Starts from the setting each time an item opens.
    @State private var masked = UserDefaults.standard.bool(forKey: Prefs.maskValues)

    /// True while the user has unmasked values that the setting would mask.
    private var revealedAll: Binding<Bool> {
        Binding(get: { maskValues && !masked }, set: { masked = !$0 })
    }

    init(item: Item, text: String) {
        self.item = item
        self.text = text
        _draft = State(initialValue: text)
    }

    private var dirty: Bool { draft != text }
    private var doc: EnvDocument { DotEnv.parse(text) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 160)
                Spacer()
                if mode == .table {
                    Toggle(isOn: $masked) { Label("Mask", systemImage: masked ? "eye.slash" : "eye") }
                        .toggleStyle(.button).help(masked ? "Show values for now" : "Mask values")
                    AddKeyButton { key, value in
                        Task { await model.updateItem(item.id, payload: .envFile(text: doc.setting(key, to: value).text)) }
                    }
                }
                Menu {
                    Button("Copy File Contents") { ClipboardService.shared.copy(text) }
                    Button("Copy as `export` Lines") { ClipboardService.shared.copy(EnvExport.shell(doc)) }
                    Button("Copy as Inline Command Prefix") { ClipboardService.shared.copy(EnvExport.inlineCommand(doc)) }
                    Button("Copy as JSON") { ClipboardService.shared.copy(EnvExport.json(doc)) }
                    Button("Copy as .env.example") { ClipboardService.shared.copy(EnvHygiene.example(from: doc), concealed: false) }
                    Divider()
                    Button("Write File to Folder…") { writeToFolder() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
                if mode == .raw {
                    Button("Revert") { draft = text }.disabled(!dirty)
                    Button("Save") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            switch mode {
            case .table:
                EnvTableView(doc: doc, masked: masked, keyAges: keyAges) { key, value in
                    Task { await model.updateItem(item.id, payload: .envFile(text: doc.setting(key, to: value).text)) }
                } onDelete: { key in
                    Task { await model.updateItem(item.id, payload: .envFile(text: doc.removing(key).text)) }
                }
            case .raw:
                CodeTextView(text: $draft)
            }
        }
        .onChange(of: text) { _, new in if !dirty || mode == .table { draft = new } }
        .onChange(of: maskValues) { _, new in masked = new }
        .autoMask(revealedAll)
        .task(id: item.revisionId) {
            let revs = await model.history(of: item.id).compactMap { r -> (date: Date, text: String)? in
                guard case .envFile(let t) = r.payload else { return nil }
                return (r.modifiedAt, t)
            }
            keyAges = EnvHygiene.keyAges(revisions: revs)
        }
        .confirmationDialog("Replace existing file?", isPresented: Binding(get: { exportConfirm != nil }, set: { if !$0 { exportConfirm = nil } }), presenting: exportConfirm) { url in
            Button("Replace", role: .destructive) { write(to: url) }
        } message: { url in
            Text("\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().lastPathComponent).")
        }
    }

    private func save() {
        Task { await model.updateItem(item.id, payload: .envFile(text: draft)) }
    }

    private func writeToFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Write Here"
        panel.message = "Choose the project folder. “\(item.name)” will be written into it."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let target = dir.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: target.path) {
            exportConfirm = target
        } else {
            write(to: target)
        }
    }

    private func write(to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            model.errorMessage = "Could not write file: \(error.localizedDescription)"
        }
    }
}

struct AddKeyButton: View {
    let onAdd: (String, String) -> Void
    @State private var open = false
    @State private var key = ""
    @State private var value = ""

    var body: some View {
        Button { open = true } label: { Label("Add Key", systemImage: "plus") }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("KEY", text: $key).font(.system(.body, design: .monospaced))
                    TextField("value", text: $value).font(.system(.body, design: .monospaced)).onSubmit(add)
                    HStack {
                        Spacer()
                        Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(!DotEnv.isValidKey(key))
                    }
                }
                .textFieldStyle(.roundedBorder).padding(12).frame(width: 320)
            }
    }

    private func add() {
        guard DotEnv.isValidKey(key) else { return }
        onAdd(key, value)
        key = ""; value = ""; open = false
    }
}

// MARK: - Secret

struct SecretView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.maskValues) private var maskValues = true
    let item: Item
    let value: String
    let notes: String
    @State private var draftValue: String
    @State private var draftNotes: String
    @State private var revealed = false

    init(item: Item, value: String, notes: String) {
        self.item = item; self.value = value; self.notes = notes
        _draftValue = State(initialValue: value)
        _draftNotes = State(initialValue: notes)
    }

    private var dirty: Bool { draftValue != value || draftNotes != notes }

    var body: some View {
        Form {
            Section("Value") {
                HStack {
                    if revealed || !maskValues {
                        TextField("", text: $draftValue).font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("", text: $draftValue).font(.system(.body, design: .monospaced))
                    }
                    Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        .autoMask($revealed)
                    Button { ClipboardService.shared.copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                }
            }
            Section("Notes") {
                TextEditor(text: $draftNotes).frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("Revert") { draftValue = value; draftNotes = notes }.disabled(!dirty)
                Button("Save") { Task { await model.updateItem(item.id, payload: .secret(value: draftValue, notes: draftNotes)) } }
                    .keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
            }
        }
        .formStyle(.grouped)
        .onChange(of: value) { _, v in if draftValue == value { draftValue = v } }
    }
}

// MARK: - Note

struct NoteView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let markdown: String
    @State private var draft: String

    init(item: Item, markdown: String) {
        self.item = item; self.markdown = markdown
        _draft = State(initialValue: markdown)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft).font(.body).padding(8)
            Divider()
            HStack {
                Spacer()
                Button("Revert") { draft = markdown }.disabled(draft == markdown)
                Button("Save") { Task { await model.updateItem(item.id, payload: .note(markdown: draft)) } }
                    .keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(draft == markdown)
            }
            .padding(8)
        }
    }
}
