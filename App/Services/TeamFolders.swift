import Foundation

/// Where each folder-mode team vault lives on this Mac (a shared Dropbox
/// folder, a git checkout…), as security-scoped bookmarks. Per Mac: the same
/// team can sit at a different path on each one, so the personal vault only
/// records that the team exists.
@MainActor
enum TeamFolders {
    private static func key(_ vaultId: UUID) -> String { "dk.dinhkhanh.envault.teamFolder.\(vaultId.uuidString)" }
    /// Folders whose security-scoped access is running, started once each.
    private static var open: [UUID: URL] = [:]

    static func save(_ url: URL, for vaultId: UUID) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key(vaultId))
    }

    /// The folder, with security-scoped access started (once; `stop` ends it).
    static func restore(_ vaultId: UUID) -> URL? {
        if let url = open[vaultId] { return url }
        guard let data = UserDefaults.standard.data(forKey: key(vaultId)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        open[vaultId] = url
        // Re-saving a stale bookmark needs the access just started.
        if stale { try? save(url, for: vaultId) }
        return url
    }

    /// Ends access to the folder (the vault closed or the app locked).
    static func stop(_ vaultId: UUID) {
        open.removeValue(forKey: vaultId)?.stopAccessingSecurityScopedResource()
    }

    static func stopAll() {
        for id in Array(open.keys) { stop(id) }
    }

    static func forget(_ vaultId: UUID) {
        stop(vaultId)
        UserDefaults.standard.removeObject(forKey: key(vaultId))
    }
}
