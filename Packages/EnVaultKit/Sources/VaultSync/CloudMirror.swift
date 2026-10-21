import Foundation
import CryptoKit
import VaultCore

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(String)
}

/// Persisted between launches so pushes and pulls are incremental.
struct CloudMirrorState: Codable {
    var changeToken: Data?
    var uploaded: Set<String> = []
    var headerHash: String?
    var lastSync: Date?
    /// Who uploaded each join request (`identities/…`), as the server recorded it.
    var creators: [String: String]? = nil
    /// Files this Mac downloaded after someone changed them in place: in a team
    /// vault, never used to put a file back (see `pull`).
    var changed: Set<String>? = nil
}

/// Which relative paths a vault syncs. Shared zones let other Apple IDs write
/// records, so a remote path is untrusted: anything outside these shapes is
/// ignored in both directions (never written, uploaded or deleted).
public enum SyncPaths {
    /// Folders a team vault adds next to `projects/`. `spike` holds the phase 0 probes.
    static let teamFolders: Set<String> = ["identities", "keys", "members", "spike"]

    public static func isSyncable(_ path: String) -> Bool {
        if path == VaultHeader.fileName { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ isSafeComponent($0) && isCanonicalCase($0) }) else { return false }
        if parts[0] == "projects" { return path.hasSuffix(".\(RevisionFile.fileExtension)") }
        return teamFolders.contains(String(parts[0]))
    }

    /// Ids in upper case, everything else in lower case, as vaults write them.
    /// Disks are case-insensitive: a twin spelled otherwise would land on the
    /// real file, or the real file in the twin's folder.
    static func isCanonicalCase(_ c: Substring) -> Bool {
        var rest = Substring(c.lowercased()), spelled = ""
        if rest.hasPrefix("prev-") { spelled = "prev-"; rest = rest.dropFirst(5) }
        let stem = String(rest.prefix { $0 != "." })
        let isId = UUID(uuidString: stem) != nil || ULID(string: stem) != nil
        spelled += (isId ? stem.uppercased() : stem) + rest.dropFirst(stem.count)
        return spelled == c
    }

    /// Letters, digits, `.`, `_`, `-`; no leading dot, so no `.`, `..` or hidden files.
    /// No `/` or `|` either: record names encode `/` as `|`.
    static func isSafeComponent(_ c: Substring) -> Bool {
        guard let first = c.first, first != "." else { return false }
        return c.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }
}

/// Keeps a local vault folder and its cloud copy identical.
///
/// Push: every local file not yet uploaded goes up (create-only), and
/// `vault.json` goes up again whenever its content changes.
/// Pull: every remote file not present locally is written; remote deletions
/// (compaction) are applied; a changed `vault.json` replaces the local one.
///
/// Works on ciphertext only, so it can run while the vault is locked.
public actor CloudMirror {
    public let vaultId: UUID
    public let localRoot: URL
    private let transport: CloudVaultTransport
    private let stateURL: URL
    private var state: CloudMirrorState
    private let storage: LocalFolderStorage
    /// This Mac's account owns the vault's zone (it shares the vault, or it is personal).
    private let hostsZone: Bool
    public private(set) var status: SyncStatus = .idle
    public var lastSync: Date? { state.lastSync }

    public init(vaultId: UUID, localRoot: URL, stateURL: URL, transport: CloudVaultTransport, hostsZone: Bool = false) {
        self.vaultId = vaultId
        self.hostsZone = hostsZone
        self.localRoot = localRoot
        self.stateURL = stateURL
        self.transport = transport
        self.storage = LocalFolderStorage(root: localRoot)
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(CloudMirrorState.self, from: d) {
            state = s
        } else {
            state = CloudMirrorState()
        }
    }

    /// Create the remote vault and ask for change notifications.
    public func bootstrap() async throws {
        try await transport.ensureVault(vaultId)
        try? await transport.subscribe(vaultId)
    }

    /// Pull then push. Returns (filesPulled, filesPushed).
    @discardableResult
    public func sync() async -> (pulled: Int, pushed: Int) {
        status = .syncing
        do {
            let pulled = try await pull()
            let pushed = try await push()
            state.lastSync = Date()
            saveState()
            status = .idle
            return (pulled, pushed)
        } catch {
            status = .error(error.localizedDescription)
            return (0, 0)
        }
    }

    /// Whether the local copy is a team vault (format 2): its files are never deleted.
    private func isTeamVault() async -> Bool {
        guard let data = try? await storage.read(VaultPath(VaultHeader.fileName)) else { return false }
        return (try? JSONDecoder().decode(HeaderIdentity.self, from: data))?.kind == "team"
    }

    /// The CloudKit user who uploaded a join request or the vault's header, as
    /// the server recorded it when this Mac downloaded it. Nil for files this
    /// Mac wrote itself, and for files someone else changed after uploading.
    public func creator(of path: String) -> String? { state.creators?[path] }

    /// Whether a local file has reached the cloud (uploaded here, or downloaded from it).
    public func isUploaded(_ path: String) -> Bool { state.uploaded.contains(path) }

    @discardableResult
    public func pull() async throws -> Int {
        var written = 0
        var more = true
        while more {
            let changes: CloudChanges
            do {
                changes = try await transport.fetchChanges(vaultId: vaultId, since: state.changeToken)
            } catch CloudTransportError.tokenExpired {
                state.changeToken = nil
                continue
            } catch CloudTransportError.zoneMissing {
                // Nothing of this vault is in the cloud (new, deleted, or our state was
                // written against another CloudKit environment): forget what we uploaded
                // so the next push sends everything.
                try await transport.ensureVault(vaultId)
                state.changeToken = nil
                state.uploaded = []
                state.headerHash = nil
                continue
            }
            let team = await isTeamVault()
            // Team files never change once written: put back the ones someone overwrote.
            var putBack: [CloudFile] = []
            for f in changes.files {
                guard SyncPaths.isSyncable(f.path) else { continue }
                let path = VaultPath(f.path.split(separator: "/").map(String.init))
                if f.path == VaultHeader.fileName {
                    // Someone else's header (another vault's, or garbage) never replaces ours.
                    guard (try? JSONDecoder().decode(HeaderIdentity.self, from: f.data))?.vaultId == vaultId else { continue }
                    // Only act on a header we have not seen (uploaded or downloaded) before.
                    // Our own upload echoing back has the same hash and is skipped.
                    let h = Self.hash(f.data)
                    var known = state.headerHash
                    let local = try? await storage.read(path)
                    if known == nil, let local { known = Self.hash(local) }
                    // A team vault's header is written once and never replaced: a
                    // different one in the zone is someone's swap. Keep ours; the
                    // next push puts it back.
                    if h != known, let local, (try? JSONDecoder().decode(HeaderIdentity.self, from: local))?.kind == "team" {
                        state.headerHash = h
                        continue
                    }
                    // Someone re-saved the zone owner's header (same bytes, so nobody
                    // else re-uploads it): first joins would refuse it. The owner's Mac
                    // saves it again, which makes the owner its last modifier.
                    if hostsZone, team, f.creator == nil, let local { putBack.append(CloudFile(path: f.path, data: local)) }
                    // Who wrote the header we keep, a first-time joiner checks it is the zone's
                    // owner. Never recorded for one refused above: it would vouch for ours.
                    var creators = state.creators ?? [:]
                    creators[f.path] = f.creator
                    state.creators = creators
                    if h != known {
                        try await storage.writeReplace(path, data: f.data)
                        written += 1
                    }
                    state.headerHash = h
                    continue
                }
                if f.path.hasPrefix("identities/"), let c = f.creator, state.creators?[f.path] == nil {
                    state.creators = (state.creators ?? [:]).merging([f.path: c]) { a, _ in a }
                }
                if team, let local = try? await storage.read(path), local != f.data {
                    if state.changed?.contains(f.path) == true {
                        // Ours came overwritten: follow the zone, and trust it again once
                        // the record is as its uploader left it.
                        try await storage.writeReplace(path, data: f.data)
                        if f.creator != nil { state.changed?.remove(f.path) }
                        written += 1
                    } else if f.creator == nil {
                        // Overwritten in place (a create-only upload that lost the race
                        // differs too, but its record's uploader is its last modifier).
                        putBack.append(CloudFile(path: f.path, data: local))
                    }
                    state.uploaded.insert(f.path)
                    continue
                }
                // Echo of our own upload (possibly compacted away since): ignore.
                if state.uploaded.contains(f.path) { continue }
                if try await !storage.exists(path) {
                    try await storage.writeNew(path, data: f.data)
                    // Not only in team vaults: a first download may come before the header.
                    if f.creator == nil { state.changed = (state.changed ?? []).union([f.path]) }
                    written += 1
                }
                state.uploaded.insert(f.path)
            }
            for p in changes.deletedPaths where SyncPaths.isSyncable(p) {
                let path = VaultPath(p.split(separator: "/").map(String.init))
                // Team vaults never delete anything (no compaction), so a deletion
                // there is someone erasing history or undoing a removal: keep the
                // local file, and the next push puts it back.
                if !team, try await storage.exists(path) { try await storage.delete(path) }
                // A join request put back by anyone but its author would name them as
                // its uploader, and the share upkeep would match the wrong person.
                if team, p.hasPrefix("identities/"), state.creators?[p] != nil || state.changed?.contains(p) == true { continue }
                // The header goes up again on the next push (it is never in `uploaded`).
                if team, p == VaultHeader.fileName { state.headerHash = nil }
                state.uploaded.remove(p)
            }
            if !putBack.isEmpty { try await transport.upload(putBack, vaultId: vaultId, overwrite: true) }
            state.changeToken = changes.token
            more = changes.moreComing
            saveState()
        }
        return written
    }

    @discardableResult
    public func push() async throws -> Int {
        var toUpload: [CloudFile] = []
        var headerUpload: CloudFile?
        for rel in localFiles() {
            let path = VaultPath(rel.split(separator: "/").map(String.init))
            if rel == VaultHeader.fileName {
                let data = try await storage.read(path)
                if Self.hash(data) != state.headerHash { headerUpload = CloudFile(path: rel, data: data) }
            } else if !state.uploaded.contains(rel) {
                toUpload.append(CloudFile(path: rel, data: try await storage.read(path)))
            }
        }
        var pushed = 0
        for chunk in toUpload.chunked(100) {
            try await transport.upload(chunk, vaultId: vaultId, overwrite: false)
            for f in chunk { state.uploaded.insert(f.path) }
            pushed += chunk.count
            saveState()
        }
        if let h = headerUpload {
            try await transport.upload([h], vaultId: vaultId, overwrite: true)
            state.headerHash = Self.hash(h.data)
            pushed += 1
            saveState()
        }
        // Local deletions (compaction) → remote deletions. Never for a team vault:
        // a file missing here was deleted by someone, not compacted.
        if await isTeamVault() { return pushed }
        let local = Set(localFiles())
        let gone = state.uploaded.filter { !local.contains($0) && $0 != VaultHeader.fileName && SyncPaths.isSyncable($0) }
        if !gone.isEmpty {
            try await transport.delete(paths: Array(gone), vaultId: vaultId)
            state.uploaded.subtract(gone)
            saveState()
        }
        return pushed
    }

    // MARK: - helpers

    /// Relative paths of every local file `SyncPaths` accepts: `vault.json`,
    /// revisions under `projects/`, and the team folders.
    func localFiles() -> [String] {
        let fm = FileManager.default
        let base = localRoot.resolvingSymlinksInPath().path + "/"
        guard let e = fm.enumerator(at: localRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = u.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if SyncPaths.isSyncable(rel) { out.append(rel) }
        }
        return out.sorted()
    }

    static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// Forget sync state (not the files). Next sync re-uploads/re-downloads as needed.
    public func reset() {
        state = CloudMirrorState()
        saveState()
    }
}

/// Just enough of a header to see which vault it belongs to.
private struct HeaderIdentity: Decodable {
    var vaultId: UUID
    var kind: String?
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
