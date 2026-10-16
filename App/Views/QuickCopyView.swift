import SwiftUI
import AppKit
import VaultCore
import EnvKit

/// One copyable thing: an env key, a secret, or a note.
struct QuickCopyHit: Identifiable, Hashable {
    enum Kind: Hashable { case env, secret, note }
    let id: String
    let kind: Kind
    let project: String
    let item: String
    let key: String
    let value: String
    let notes: String
}

/// Search over every key, secret and note in the unlocked vault. Ranks key
/// matches above item/project/notes, and recently copied hits first.
enum QuickCopyIndex {
    static func hits(items: [Item], projects: [Project]) -> [QuickCopyHit] {
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [QuickCopyHit] = []
        for item in items {
            let project = names[item.projectId] ?? ""
            switch item.payload {
            case .envFile(let text):
                for e in DotEnv.parse(text).entries {
                    out.append(QuickCopyHit(id: "\(item.id)/\(e.key)", kind: .env, project: project, item: item.name, key: e.key, value: e.value, notes: e.inlineComment ?? ""))
                }
            case .secret(let v, let notes):
                out.append(QuickCopyHit(id: item.id.uuidString, kind: .secret, project: project, item: item.name, key: item.name, value: v, notes: notes))
            case .note(let md):
                out.append(QuickCopyHit(id: item.id.uuidString, kind: .note, project: project, item: item.name, key: item.name, value: md, notes: md))
            case .unknown:
                break
            }
        }
        return out
    }

    static func search(_ all: [QuickCopyHit], query: String, recents: [String], limit: Int = 50) -> [QuickCopyHit] {
        let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty {
            let recent = all.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            return Array((recent + all.filter { rank[$0.id] == nil }).prefix(limit))
        }
        var scored: [(QuickCopyHit, Int)] = []
        for h in all {
            let key = h.key.lowercased(), item = h.item.lowercased(), project = h.project.lowercased(), notes = h.notes.lowercased()
            var total = 0
            var matchedAll = true
            for t in tokens {
                var s = 0
                if key == t { s = 100 } else if key.hasPrefix(t) { s = 60 } else if key.contains(t) { s = 40 }
                else if item.contains(t) { s = 20 } else if project.contains(t) { s = 15 }
                else if notes.contains(t) { s = 8 }
                // Values only for longer queries, so a few letters don't match every token.
                else if h.kind != .note, t.count >= 4, h.value.lowercased().contains(t) { s = 5 }
                if s == 0 { matchedAll = false; break }
                total += s
            }
            guard matchedAll else { continue }
            if let r = rank[h.id] { total += max(0, 30 - r) }
            scored.append((h, total))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: Prefs.quickCopyRecents) ?? [] }

    static func noteCopied(_ id: String) {
        var r = recents.filter { $0 != id }
        r.insert(id, at: 0)
        UserDefaults.standard.set(Array(r.prefix(20)), forKey: Prefs.quickCopyRecents)
    }
}

/// The search-and-copy list, used by the menu bar extra and the hotkey panel.
struct QuickCopyView: View {
    enum Style { case menu, panel }
    @Environment(AppModel.self) private var model
    @Environment(LicenseManager.self) private var licenses
    let style: Style
    let openMain: () -> Void
    var onDone: () -> Void = {}

    @State private var query = ""
    @State private var selection = 0
    @State private var copiedId: String?
    @State private var recents = QuickCopyIndex.recents
    @FocusState private var focused: Bool

    private var hits: [QuickCopyHit] {
        guard model.phase == .unlocked else { return [] }
        return QuickCopyIndex.search(QuickCopyIndex.hits(items: model.items, projects: model.projects), query: query, recents: recents)
    }

    var body: some View {
        Group {
            if model.phase == .unlocked, !licenses.allows(.menuBarQuickCopy) {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title)
                    Text("Quick copy is part of EnVault Pro.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Learn More") { licenses.upgradePrompt = .menuBarQuickCopy; openMain() }.buttonStyle(.borderedProminent)
                }
                .padding(24).frame(maxWidth: .infinity)
            } else if model.phase == .unlocked {
                searchList
            } else {
                lockedView
            }
        }
    }

    private var searchList: some View {
        let hits = hits
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(style == .panel ? "Search keys, secrets and notes" : "Search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(style == .panel ? .title3 : .body)
                    .focused($focused)
                    .onKeyPress(phases: .down) { press in handle(press, hits: hits) }
            }
            .padding(style == .panel ? 14 : 8)
            Divider()
            if hits.isEmpty {
                Text(model.items.isEmpty ? "The vault is empty." : "No matches.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(hits.enumerated()), id: \.element.id) { idx, h in
                        HitRow(hit: h, selected: idx == selection, copied: copiedId == h.id)
                            .contentShape(Rectangle())
                            .onTapGesture { copy(h, as: .value) }
                            .contextMenu {
                                Button("Copy Value") { copy(h, as: .value) }
                                if h.kind == .env {
                                    Button("Copy as export Line") { copy(h, as: .export) }
                                    Button("Copy KEY=value") { copy(h, as: .assignment) }
                                }
                                Button("Copy Name") { copy(h, as: .name) }
                            }
                            .id(idx)
                            .listRowBackground(idx == selection && style == .panel ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { _, s in proxy.scrollTo(s) }
                }
            }
            if style == .panel {
                Divider()
                Text("↩ copy value   ⌥↩ export line   ⌘↩ KEY=value   ⇧↩ name   esc close")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onAppear { focused = true; recents = QuickCopyIndex.recents }
    }

    private var lockedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.title)
            Text(model.phase == .noVault ? "No vault open" : "Vault is locked").foregroundStyle(.secondary)
            if model.phase == .locked, model.hasBiometricKey {
                Button("Unlock with Touch ID") { Task { await model.unlockWithBiometrics() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Open EnVault") { openMain() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ press: KeyPress, hits: [QuickCopyHit]) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            selection = min(selection + 1, max(hits.count - 1, 0)); return .handled
        case .upArrow:
            selection = max(selection - 1, 0); return .handled
        case .escape:
            onDone(); return .handled
        case .return:
            guard hits.indices.contains(selection) else { return .handled }
            let h = hits[selection]
            if press.modifiers.contains(.option) { copy(h, as: .export) }
            else if press.modifiers.contains(.command) { copy(h, as: .assignment) }
            else if press.modifiers.contains(.shift) { copy(h, as: .name) }
            else { copy(h, as: .value) }
            return .handled
        default:
            return .ignored
        }
    }

    enum CopyForm { case value, export, assignment, name }

    private func copy(_ h: QuickCopyHit, as form: CopyForm) {
        switch form {
        case .value: ClipboardService.shared.copy(h.value)
        case .export: ClipboardService.shared.copy("export \(h.key)=\(EnvExport.shellQuote(h.value))")
        case .assignment: ClipboardService.shared.copy("\(h.key)=\(h.value)")
        case .name: ClipboardService.shared.copy(h.key, concealed: false)
        }
        QuickCopyIndex.noteCopied(h.id)
        copiedId = h.id
        Task {
            try? await Task.sleep(for: .milliseconds(style == .panel ? 350 : 1000))
            copiedId = nil
            if style == .panel { onDone() }
        }
    }
}

private struct HitRow: View {
    let hit: QuickCopyHit
    let selected: Bool
    let copied: Bool

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.key).font(.system(.body, design: .monospaced)).lineLimit(1)
                Text("\(hit.project) › \(hit.item)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(copied ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch hit.kind {
        case .env: "doc.text"
        case .secret: "key"
        case .note: "note.text"
        }
    }
}

// MARK: - Hotkey panel

/// A Spotlight-style floating panel. Non-activating, so the app you were in
/// stays frontmost and you can paste straight back into it.
final class QuickCopyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class QuickCopyPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickCopyPanelController()

    private var panel: QuickCopyPanel?
    private var model: AppModel?
    private var licenses: LicenseManager?
    /// Opens the main window; set by the app scene, which has `openWindow`.
    var openMain: (() -> Void)?

    func configure(model: AppModel, licenses: LicenseManager) {
        self.model = model
        self.licenses = licenses
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        guard let model, let licenses else { return }
        let p = panel ?? makePanel()
        panel = p
        let root = QuickCopyView(style: .panel, openMain: { [weak self] in self?.hide(); self?.showMainWindow() }, onDone: { [weak self] in self?.hide() })
            .environment(model)
            .environment(licenses)
            .frame(width: 600, height: 400)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        p.contentView = NSHostingView(rootView: root)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.minY + f.height * 0.62 - 200))
        }
        p.makeKeyAndOrderFront(nil)
        model.userActivity()
    }

    func hide() { panel?.orderOut(nil) }

    private func showMainWindow() {
        if let openMain { openMain(); return }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> QuickCopyPanel {
        let p = QuickCopyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        return p
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { hide() }
    }
}
