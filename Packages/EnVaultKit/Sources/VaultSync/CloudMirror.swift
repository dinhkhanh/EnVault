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
    public private(set) var status: SyncStatus = .idle
    public var lastSync: Date? { state.lastSync }

    public init(vaultId: UUID, localRoot: URL, stateURL: URL, transport: CloudVaultTransport) {
        self.vaultId = vaultId
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
            for f in changes.files {
                let path = VaultPath(f.path.split(separator: "/").map(String.init))
                if f.path == VaultHeader.fileName {
                    // Only act on a header we have not seen (uploaded or downloaded) before.
                    // Our own upload echoing back has the same hash and is skipped.
                    let h = Self.hash(f.data)
                    var known = state.headerHash
                    if known == nil, let local = try? await storage.read(path) { known = Self.hash(local) }
                    if h != known {
                        try await storage.writeReplace(path, data: f.data)
                        written += 1
                    }
                    state.headerHash = h
                    continue
                }
                // Echo of our own upload (possibly compacted away since): ignore.
                if state.uploaded.contains(f.path) { continue }
                if try await !storage.exists(path) {
                    try await storage.writeNew(path, data: f.data)
                    written += 1
                }
                state.uploaded.insert(f.path)
            }
            for p in changes.deletedPaths {
                let path = VaultPath(p.split(separator: "/").map(String.init))
                if try await storage.exists(path) { try await storage.delete(path) }
                state.uploaded.remove(p)
            }
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
        // Local deletions (compaction) → remote deletions.
        let local = Set(localFiles())
        let gone = state.uploaded.filter { !local.contains($0) && $0 != VaultHeader.fileName }
        if !gone.isEmpty {
            try await transport.delete(paths: Array(gone), vaultId: vaultId)
            state.uploaded.subtract(gone)
            saveState()
        }
        return pushed
    }

    // MARK: - helpers

    /// Relative paths of `vault.json` and every visible file in the vault's
    /// subfolders (`projects/` today; team vaults add more). Anything pulled is
    /// therefore also kept: a remote file outside `projects/` is not mistaken
    /// for a local deletion on the next push.
    func localFiles() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: localRoot.appendingPathComponent(VaultHeader.fileName).path) { out.append(VaultHeader.fileName) }
        let base = localRoot.resolvingSymlinksInPath().path + "/"
        let top = (try? fm.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in top where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let full = u.resolvingSymlinksInPath().path
                guard full.hasPrefix(base) else { continue }
                out.append(String(full.dropFirst(base.count)))
            }
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

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
