import Foundation
import CryptoKit
import VaultCore

/// An item kept written to a file in a project folder ("Keep in Sync with a
/// Folder…"). Per Mac: stored in the app container, never in the vault.
struct FileLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var vaultId: UUID
    var itemId: UUID
    /// Security-scoped bookmark of the folder.
    var bookmark: Data
    var folderPath: String
    var fileName: String
    /// Delete the file while the vault is locked (if nobody edited it).
    var removeWhenLocked = false
    /// SHA-256 of what eVault last wrote, to tell our writes from edits on disk.
    var lastWrittenHash: String?
    var lastWrittenAt: Date?

    var filePath: String { (folderPath as NSString).appendingPathComponent(fileName) }
}

enum FileLinkStatus: Equatable {
    case synced(Date?)
    /// The file on disk differs from both the vault and what eVault last wrote.
    case changedOnDisk
    case removedWhileLocked
    case itemDeleted
    case failed(String)
}

/// Writes linked items into their folders whenever the vault changes (edits
/// here, on another Mac, or from the CLI), without clobbering edits made on disk.
@MainActor
@Observable
final class FileLinkStore {
    private(set) var links: [FileLink] = []
    private(set) var status: [UUID: FileLinkStatus] = [:]

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("eVault/FileLinks.json")
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
        sync(link.id, item: item, force: false)
        return link
    }

    func remove(_ id: UUID) {
        links.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    func setRemoveWhenLocked(_ id: UUID, _ on: Bool) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        links[i].removeWhenLocked = on
        save()
    }

    /// Brings every link of this vault up to date with `items`.
    func syncAll(items: [Item], vaultId: UUID) {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for link in links where link.vaultId == vaultId {
            guard let item = byId[link.itemId] else { status[link.id] = .itemDeleted; continue }
            sync(link.id, item: item, force: false)
        }
    }

    /// Brings just this item's links up to date (and notices edits made on disk).
    func syncItem(_ item: Item) {
        for link in links where link.itemId == item.id { sync(link.id, item: item, force: false) }
    }

    /// Writes the vault's version, replacing whatever is on disk.
    func overwrite(_ id: UUID, item: Item) { sync(id, item: item, force: true) }

    /// The file's current text, for "Import Disk Version".
    func diskText(_ id: UUID) -> String? {
        guard let link = links.first(where: { $0.id == id }) else { return nil }
        return withFolder(link) { try? String(contentsOf: $0.appendingPathComponent(link.fileName), encoding: .utf8) } ?? nil
    }

    /// Vault locked: remove the files of links that ask for it, unless they were edited on disk.
    func vaultLocked(vaultId: UUID) {
        for link in links where link.vaultId == vaultId && link.removeWhenLocked {
            withFolder(link) { folder in
                let target = folder.appendingPathComponent(link.fileName)
                guard let disk = try? String(contentsOf: target, encoding: .utf8), Self.hash(disk) == link.lastWrittenHash else { return }
                try? FileManager.default.removeItem(at: target)
                status[link.id] = .removedWhileLocked
            }
        }
    }

    private func sync(_ id: UUID, item: Item, force: Bool) {
        guard let i = links.firstIndex(where: { $0.id == id }) else { return }
        let link = links[i]
        let content = item.payload.primaryText
        let contentHash = Self.hash(content)
        let result: FileLinkStatus? = withFolder(link) { folder in
            let target = folder.appendingPathComponent(link.fileName)
            let disk = try? String(contentsOf: target, encoding: .utf8)
            let diskHash = disk.map(Self.hash)
            if diskHash == contentHash {
                if links[i].lastWrittenHash != contentHash { links[i].lastWrittenHash = contentHash; links[i].lastWrittenAt = Date(); save() }
                return .synced(links[i].lastWrittenAt)
            }
            if !force, let diskHash, diskHash != link.lastWrittenHash { return .changedOnDisk }
            do {
                try content.write(to: target, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                links[i].lastWrittenHash = contentHash
                links[i].lastWrittenAt = Date()
                save()
                return .synced(links[i].lastWrittenAt)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        status[id] = result ?? .failed("The folder \(link.folderPath) is no longer available.")
    }

    /// Runs `body` with access to the link's folder; nil if the bookmark no longer resolves.
    @discardableResult
    private func withFolder<T>(_ link: FileLink, _ body: (URL) -> T) -> T? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: link.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
           let i = links.firstIndex(where: { $0.id == link.id }) {
            links[i].bookmark = fresh
            save()
        }
        return body(url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(links).write(to: fileURL, options: .atomic)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
