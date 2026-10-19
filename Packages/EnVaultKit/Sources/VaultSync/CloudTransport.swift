import Foundation

/// One file of a vault as it travels through the cloud. Always ciphertext
/// (or the public `vault.json` header).
public struct CloudFile: Hashable, Sendable {
    public var path: String
    public var data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}

public struct CloudChanges: Sendable {
    public var files: [CloudFile]
    public var deletedPaths: [String]
    public var token: Data?
    public var moreComing: Bool
    public init(files: [CloudFile], deletedPaths: [String], token: Data?, moreComing: Bool) {
        self.files = files; self.deletedPaths = deletedPaths; self.token = token; self.moreComing = moreComing
    }
}

public enum CloudTransportError: Error, Sendable, Equatable {
    case tokenExpired
    case zoneMissing
    case notSignedIn
    /// A shared vault this user may only read (or no longer may use at all).
    case permissionDenied
    case other(String)
}

/// The minimal cloud API the mirror needs. `CloudKitTransport` implements it
/// against the user's private CloudKit database; `MemoryCloudTransport` is
/// used by tests and previews.
public protocol CloudVaultTransport: Sendable {
    /// Create the per-vault container (idempotent).
    func ensureVault(_ vaultId: UUID) async throws
    /// Ask for silent pushes when the vault changes (best effort).
    func subscribe(_ vaultId: UUID) async throws
    /// Upload files. With `overwrite == false`, an already-existing path is
    /// not an error (immutable files are identical by construction).
    func upload(_ files: [CloudFile], vaultId: UUID, overwrite: Bool) async throws
    func delete(paths: [String], vaultId: UUID) async throws
    /// Incremental changes since `token` (nil = everything).
    func fetchChanges(vaultId: UUID, since token: Data?) async throws -> CloudChanges
    /// Vault ids present in the account.
    func listVaults() async throws -> [UUID]
    /// One file, or nil if it does not exist.
    func fetchFile(path: String, vaultId: UUID) async throws -> Data?
}

/// In-memory transport: an append-only event log per vault, so change tokens
/// are just positions in the log. Mirrors exactly how the mirror sees CloudKit.
public actor MemoryCloudTransport: CloudVaultTransport {
    private struct Event { let seq: Int; let path: String; let data: Data? }
    private var logs: [UUID: [Event]] = [:]
    private var seq = 0
    public var subscribed: Set<UUID> = []

    public init() {}

    private func current(_ vaultId: UUID) -> [String: Data] {
        var out: [String: Data] = [:]
        for e in logs[vaultId] ?? [] { out[e.path] = e.data }
        return out.compactMapValues { $0 }
    }

    public func ensureVault(_ vaultId: UUID) async throws {
        if logs[vaultId] == nil { logs[vaultId] = [] }
    }

    public func subscribe(_ vaultId: UUID) async throws { subscribed.insert(vaultId) }

    public func upload(_ files: [CloudFile], vaultId: UUID, overwrite: Bool) async throws {
        guard logs[vaultId] != nil else { throw CloudTransportError.zoneMissing }
        let existing = current(vaultId)
        for f in files {
            if existing[f.path] != nil, !overwrite { continue }
            seq += 1
            logs[vaultId]!.append(Event(seq: seq, path: f.path, data: f.data))
        }
    }

    public func delete(paths: [String], vaultId: UUID) async throws {
        for p in paths {
            seq += 1
            logs[vaultId, default: []].append(Event(seq: seq, path: p, data: nil))
        }
    }

    public func fetchChanges(vaultId: UUID, since token: Data?) async throws -> CloudChanges {
        guard let log = logs[vaultId] else { throw CloudTransportError.zoneMissing }
        let since = token.map { Int(String(decoding: $0, as: UTF8.self)) ?? 0 } ?? 0
        let events = log.filter { $0.seq > since }
        // Collapse to the latest state per path within the batch, like CloudKit does.
        var latest: [String: Event] = [:]
        for e in events { latest[e.path] = e }
        let files = latest.values.filter { $0.data != nil }.sorted { $0.seq < $1.seq }.map { CloudFile(path: $0.path, data: $0.data!) }
        let deleted = latest.values.filter { $0.data == nil }.map(\.path)
        let newSeq = log.last?.seq ?? since
        return CloudChanges(files: files, deletedPaths: deleted, token: Data(String(newSeq).utf8), moreComing: false)
    }

    public func listVaults() async throws -> [UUID] { Array(logs.keys) }

    public func fetchFile(path: String, vaultId: UUID) async throws -> Data? { current(vaultId)[path] }

    /// Test helper.
    public func fileCount(_ vaultId: UUID) -> Int { current(vaultId).count }
}
