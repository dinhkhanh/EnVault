import Foundation

/// Remembers the vault folder across launches via a security-scoped bookmark
/// (required under App Sandbox; also what lets us use the iCloud Drive folder).
enum VaultLocation {
    private static let key = "dk.dinhkhanh.evault.vaultBookmark"

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Resolves the saved folder and starts security-scoped access. The caller
    /// keeps the returned URL alive for the lifetime of the session.
    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? save(url) }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
