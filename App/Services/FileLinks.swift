import Foundation
import VaultCore
import VaultSync
import EnvKit

/// An item kept in sync with a file in a project folder ("Keep in Sync with a
/// Folder…"). Per Mac: stored in the app container, never in the vault.
struct FileLink: Codable, Identifiable, Hashable {
    enum Change: String, Codable { case toFile, fromFile, merged }

    var id = UUID()
    var vaultId: UUID
    var itemId: UUID
    /// Security-scoped bookmark of the folder.
    var bookmark: Data
    var folderPath: String
    var fileName: String
    /// Delete the file while the vault is locked (if nobody edited it).
    var removeWhenLocked = false
    /// SHA-256 of what EnVault last wrote to the file or saved from it, to tell
    /// which side changed since.
    var lastWrittenHash: String?
    var lastWrittenAt: Date?
    /// Which way the last change went, for the status line.
    var lastChange: Change?
    /// Optional so links saved before two-way sync decode; nil means on.
    private var importsEdits: Bool?

    /// Save edits made in the file to the vault (otherwise ask each time).
    var importEdits: Bool {
        get { importsEdits ?? true }
        set { importsEdits = newValue }
    }

    var filePath: String { (folderPath as NSString).appendingPathComponent(fileName) }

    init(vaultId: UUID, itemId: UUID, bookmark: Data, folderPath: String, fileName: String) {
        self.vaultId = vaultId; self.itemId = itemId; self.bookmark = bookmark; self.folderPath = folderPath; self.fileName = fileName
    }
}

enum FileLinkStatus: Equatable {
    case synced(Date?)
    /// Edited on disk, and the link doesn't save edits to the vault.
    case changedOnDisk
    /// Edited in the file and in EnVault, on these keys (empty: no common version to compare with).
    case conflict([String])
    case removedWhileLocked
    case itemDeleted
    case failed(String)
}

/// Keeps linked files and their vault items in step, both ways, while the
/// vault is unlocked: vault changes (here, on another Mac, from the CLI) are
/// written to the file; edits made in the file are saved as a new revision;
/// edits on both sides are merged key by key, and only the same key changed
/// in both places is left for the user to decide. Edits made while locked are
/// picked up at the next unlock.
@MainActor
@Observable
final class FileLinkStore {
    struct Hooks {
        /// The item as it is now; nil if deleted (or the vault is locked).
        var item: @MainActor (UUID) -> Item?
        var history: @MainActor (UUID) async -> [ItemRevision]
        /// Saves a new revision; false if that failed.
        var save: @MainActor (UUID, ItemPayload) async -> Bool
    }

    private(set) var links: [FileLink] = []
    private(set) var status: [UUID: FileLinkStatus] = [:]
    @ObservationIgnored var hooks: Hooks?

    private enum Mode { case normal, useVault, useFile }
    @ObservationIgnored private var running: Set<UUID> = []
    @ObservationIgnored private var rerun: [UUID: Mode] = [:]
    /// The unlocked vault whose links are synced and watched; nil while locked.
    @ObservationIgnored private var activeVault: UUID?
    @ObservationIgnored private var watchers: [String: Watch] = [:]

    private struct Watch {
        let watcher: FolderWatcher
        let task: Task<Void, Never>
        let scopedURL: URL?
    }

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("EnVault/FileLinks.json")
    }()

    init() {
        if let d = try? Data(contentsOf: fileURL), let l = try? JSONDecoder().decode([FileLink].self, from: d) { links = l }
    }

    func links(for itemId: UUID) -> [FileLink] { links.filter { $0.itemId == itemId } }

    @discardableResult
    func add(folder: URL, fileName: String, item: Item, vaultId: UUID) throws -> FileLink {
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let link = FileLink(vaultId: vaultId, itemId: item.id, bookmark: bookmark, folderPath: folder.path(percentEncoded: false), fileName: fileName)
        links.removeAll { $0.itemId == item.id && $0.filePath == link.filePath }
        links.append(link)
        save()
        updateWatchers()
        schedule(link.id)
        return link
    }

    func remove(_ id: UUID) {
        links.removeAll { $0.id == id }
        status[id] = nil
        save()
        updateWatchers()
    }

    func setRemoveWhenLocked(_ id: UUID, _ on: Bool) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        links[i].removeWhenLocked = on
        save()
    }

    func setImportEdits(_ id: UUID, _ on: Bool) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        links[i].importEdits = on
        save()
        schedule(id)
    }

    // MARK: - Unlocked / locked

    /// Vault unlocked: start watching its linked folders and catch up on both sides.
    func vaultUnlocked(vaultId: UUID) {
        activeVault = vaultId
        updateWatchers()
        syncAll(vaultId: vaultId)
    }

    /// Vault locked: stop watching, then remove the files of links that ask for
    /// it, unless they were edited since EnVault last wrote them.
    func vaultLocked(vaultId: UUID) {
        activeVault = nil
        updateWatchers()
        rerun.removeAll()
        for link in links where link.vaultId == vaultId && link.removeWhenLocked {
            withFolder(link) { folder in
                let target = folder.appendingPathComponent(link.fileName)
                guard let disk = try? String(contentsOf: target, encoding: .utf8), LinkedFileSync.hash(disk) == link.lastWrittenHash else { return }
                try? FileManager.default.removeItem(at: target)
                status[link.id] = .removedWhileLocked
            }
        }
    }

    // MARK: - Syncing

    /// Brings every link of this vault up to date, both ways.
    func syncAll(vaultId: UUID) {
        for link in links where link.vaultId == vaultId { schedule(link.id) }
    }

    /// Brings just this item's links up to date.
    func syncItem(_ itemId: UUID) {
        for link in links where link.itemId == itemId { schedule(link.id) }
    }

    /// Writes the vault's version, replacing the file.
    func overwrite(_ id: UUID) { schedule(id, .useVault) }

    /// Saves the file's text as the item's new revision.
    func useFileVersion(_ id: UUID) { schedule(id, .useFile) }

    /// One run per link at a time; a request during a run runs again after it.
    private func schedule(_ id: UUID, _ mode: Mode = .normal) {
        if running.contains(id) {
            if mode != .normal || rerun[id] == nil { rerun[id] = mode }
            return
        }
        running.insert(id)
        Task {
            await run(id, mode)
            running.remove(id)
            if let next = rerun.removeValue(forKey: id) { schedule(id, next) }
        }
    }

    private func run(_ id: UUID, _ mode: Mode) async {
        guard let link = links.first(where: { $0.id == id }), link.vaultId == activeVault, let hooks else { return }
        guard let item = hooks.item(link.itemId) else { status[id] = .itemDeleted; return }
        let vault = item.payload.primaryText
        guard let disk = readFile(link) else {
            status[id] = .failed("The folder \(link.folderPath) is no longer available.")
            return
        }

        let action: LinkedFileSync.Action
        switch mode {
        case .useVault:
            action = disk == vault ? .none : .writeFile(vault)
        case .useFile:
            if let disk { action = disk == vault ? .none : .saveToVault(disk) } else { action = .writeFile(vault) }
        case .normal:
            var base: String?
            if case .envFile = item.payload, LinkedFileSync.needsBase(disk: disk, vault: vault, lastWritten: link.lastWrittenHash, importEdits: link.importEdits) {
                // The revision last written to the file: the common version both sides were edited from.
                base = await hooks.history(item.id).first { LinkedFileSync.hash($0.payload.primaryText) == link.lastWrittenHash }?.payload.primaryText
            }
            action = LinkedFileSync.plan(disk: disk, vault: vault, lastWritten: link.lastWrittenHash, importEdits: link.importEdits, base: base)
        }
        // Changed while we looked? Start over with the newer state.
        guard link.vaultId == activeVault, hooks.item(item.id)?.revisionId == item.revisionId, readFile(link) == disk else {
            if rerun[id] == nil { rerun[id] = mode }
            return
        }

        switch action {
        case .none:
            if link.lastWrittenHash != LinkedFileSync.hash(vault) { record(id, vault, nil) }
            status[id] = .synced(links.first { $0.id == id }?.lastWrittenAt)
        case .writeFile(let text):
            write(id, link, text, .toFile)
        case .saveToVault(let text):
            guard await hooks.save(item.id, item.payload.replacingPrimaryText(text)) else {
                status[id] = .failed("Could not save the file’s edits to EnVault.")
                return
            }
            record(id, text, .fromFile)
            status[id] = .synced(Date())
        case .merged(let text):
            guard await hooks.save(item.id, item.payload.replacingPrimaryText(text)) else {
                status[id] = .failed("Could not save the merged file to EnVault.")
                return
            }
            write(id, link, text, .merged)
        case .conflict(let keys):
            status[id] = .conflict(keys)
        case .editedOnDisk:
            status[id] = .changedOnDisk
        }
    }

    /// The file's text: .some(nil) when it doesn't exist, nil when the folder can't be reached.
    private func readFile(_ link: FileLink) -> String?? {
        withFolder(link) { folder in try? String(contentsOf: folder.appendingPathComponent(link.fileName), encoding: .utf8) }
    }

    private func write(_ id: UUID, _ link: FileLink, _ text: String, _ change: FileLink.Change) {
        let result: FileLinkStatus? = withFolder(link) { folder in
            let target = folder.appendingPathComponent(link.fileName)
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                record(id, text, change)
                return .synced(Date())
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        status[id] = result ?? .failed("The folder \(link.folderPath) is no longer available.")
    }

    private func record(_ id: UUID, _ text: String, _ change: FileLink.Change?) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        links[i].lastWrittenHash = LinkedFileSync.hash(text)
        links[i].lastWrittenAt = Date()
        if let change { links[i].lastChange = change }
        save()
    }

    // MARK: - Watching

    /// One FSEvents watcher per linked folder of the unlocked vault. Events
    /// arrive coalesced about a second after the last write, so an editor's
    /// save (temporary file, then rename) is read once, complete.
    private func updateWatchers() {
        let wanted = Dictionary(grouping: links.filter { $0.vaultId == activeVault }, by: \.folderPath)
        for (path, w) in watchers where wanted[path] == nil {
            w.task.cancel()
            w.watcher.stop()
            w.scopedURL?.stopAccessingSecurityScopedResource()
            watchers[path] = nil
        }
        for (path, group) in wanted where watchers[path] == nil {
            guard let url = resolve(group[0]) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            let watcher = FolderWatcher(url: url)
            let task = Task { [weak self] in
                for await _ in watcher.changes {
                    guard let self, !Task.isCancelled else { return }
                    for link in self.links where link.folderPath == path && link.vaultId == self.activeVault { self.schedule(link.id) }
                }
            }
            watchers[path] = Watch(watcher: watcher, task: task, scopedURL: scoped ? url : nil)
        }
    }

    // MARK: - Folder access

    private func resolve(_ link: FileLink) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: link.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
           let i = links.firstIndex(where: { $0.id == link.id }) {
            links[i].bookmark = fresh
            save()
        }
        return url
    }

    /// Runs `body` with access to the link's folder; nil if the bookmark no longer resolves.
    @discardableResult
    private func withFolder<T>(_ link: FileLink, _ body: (URL) -> T) -> T? {
        guard let url = resolve(link) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return body(url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(links).write(to: fileURL, options: .atomic)
    }
}

private extension ItemPayload {
    /// The same kind of payload with its main text replaced.
    func replacingPrimaryText(_ text: String) -> ItemPayload {
        switch self {
        case .envFile: return .envFile(text: text)
        case .secret(_, let notes): return .secret(value: text, notes: notes)
        case .note: return .note(markdown: text)
        case .unknown(let kind, var fields):
            fields["text"] = text
            return .unknown(kind: kind, fields: fields)
        }
    }
}
