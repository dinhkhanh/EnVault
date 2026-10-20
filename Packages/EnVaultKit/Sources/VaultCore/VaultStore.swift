import Foundation
import CryptoKit

/// The single entry point to a vault. Owns the vault key while unlocked,
/// maintains an in-memory index of all revisions, and writes new revisions.
///
/// Layout on storage:
/// ```
/// vault.json
/// projects/<projectId>/meta/<ulid>.evr
/// projects/<projectId>/items/<itemId>/<ulid>.evr
/// projects/<IdentityLayout.namespace>/identity/<identityId>/<ulid>.evr
/// ```
public actor VaultStore {
    public let storage: VaultStorage
    public let device: DeviceIdentity
    public private(set) var header: VaultHeader

    private var vaultKey: VaultKey?
    private var index = RevisionIndex()
    private var identityRevisions: [UUID: [IdentityRevision]] = [:] // sorted ascending by id

    public var isUnlocked: Bool { vaultKey != nil }
    public var vaultId: UUID { header.vaultId }

    // MARK: - Lifecycle

    private init(storage: VaultStorage, header: VaultHeader, device: DeviceIdentity, vaultKey: VaultKey? = nil) {
        self.storage = storage
        self.header = header
        self.device = device
        self.vaultKey = vaultKey
    }

    /// Creates a new vault at an empty location and returns it unlocked.
    public static func create(storage: VaultStorage, passphrase: String, device: DeviceIdentity = .current(), kdf: KDFParams = .random()) async throws -> VaultStore {
        let headerPath = VaultPath(VaultHeader.fileName)
        if try await storage.exists(headerPath) { throw VaultError.vaultAlreadyExists }
        let (header, vk) = try KeyHierarchy.createVault(passphrase: passphrase, kdf: kdf)
        try await storage.writeNew(headerPath, data: try header.encoded())
        return VaultStore(storage: storage, header: header, device: device, vaultKey: vk)
    }

    /// Opens an existing vault, locked.
    public static func open(storage: VaultStorage, device: DeviceIdentity = .current()) async throws -> VaultStore {
        let headerPath = VaultPath(VaultHeader.fileName)
        guard try await storage.exists(headerPath) else { throw VaultError.noVaultAtLocation }
        let header = try VaultHeader.decode(try await storage.read(headerPath))
        return VaultStore(storage: storage, header: header, device: device)
    }

    /// Re-reads `vault.json` (e.g. after another device changed the passphrase).
    /// The cached vault key, if any, stays valid because only the wrapping changes.
    public func reloadHeader() async throws {
        header = try VaultHeader.decode(try await storage.read(VaultPath(VaultHeader.fileName)))
    }

    public static func vaultExists(in storage: VaultStorage) async -> Bool {
        (try? await storage.exists(VaultPath(VaultHeader.fileName))) ?? false
    }

    /// Unlocks with the passphrase, indexes everything, and returns the vault
    /// key so the caller may cache it (e.g. in the Keychain behind Touch ID).
    @discardableResult
    public func unlock(passphrase: String, progress: Progress? = nil) async throws -> VaultKey {
        let vk = try KeyHierarchy.unlock(header: header, passphrase: passphrase)
        try await unlock(vaultKey: vk, progress: progress)
        return vk
    }

    /// Unlocks with a cached vault key. The key is verified against the first
    /// revision found; an empty vault accepts any key, which is harmless.
    public func unlock(vaultKey vk: VaultKey, progress: Progress? = nil) async throws {
        vaultKey = vk
        do {
            try await refresh(progress: progress)
        } catch {
            vaultKey = nil
            clearIndex()
            throw error
        }
    }

    /// The key of an unlocked vault, so the app can hand it to the CLI after the
    /// user approves (see `AgentServer`).
    public func currentVaultKey() -> VaultKey? { vaultKey }

    public func lock() {
        vaultKey = nil
        clearIndex()
    }

    private func clearIndex() {
        index = RevisionIndex()
        identityRevisions = [:]
    }

    // MARK: - Indexing

    /// Progress callback for long scans: (revisions decrypted, revisions found).
    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    /// Scans storage for revision files not yet indexed and decrypts them.
    /// Files are read in batches: per-file reads dominate, especially in iCloud Drive.
    /// Returns true when anything new was found.
    @discardableResult
    public func refresh(progress: Progress? = nil) async throws -> Bool {
        guard let vk = vaultKey else { throw VaultError.locked }
        let pending = try await RevisionLayout.scan(storage, skipping: index.indexedPaths)
        guard !pending.isEmpty else { return false }

        let total = pending.count
        var done = 0
        progress?(0, total)
        for start in stride(from: 0, to: total, by: 100) {
            let batch = Array(pending[start..<min(start + 100, total)])
            let files = try await storage.readMany(batch.map(\.path))
            for (f, data) in zip(batch, files) {
                switch f.scope {
                case .project:
                    index.insert(try RevisionFile.decode(ProjectRevision.self, from: data, vaultId: vaultId, scope: .project, ownerId: f.ownerId, revisionId: f.revisionId, key: vk))
                case .item:
                    index.insert(try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: f.ownerId, revisionId: f.revisionId, key: vk))
                case .identity:
                    let rev = try RevisionFile.decode(IdentityRevision.self, from: data, vaultId: vaultId, scope: .identity, ownerId: f.ownerId, revisionId: f.revisionId, key: vk)
                    RevisionIndex.insert(rev, into: &identityRevisions[rev.identityId, default: []])
                }
                index.indexedPaths.insert(f.path.string)
            }
            done += batch.count
            progress?(done, total)
        }
        return true
    }

    // MARK: - Reading

    public func projects(includeDeleted: Bool = false) -> [Project] { index.projects(includeDeleted: includeDeleted) }
    public func project(_ id: UUID) -> Project? { index.project(id) }
    public func items(in projectId: UUID) -> [Item] { index.items(in: projectId) }
    public func allItems() -> [Item] { index.allItems() }
    public func item(_ id: UUID) -> Item? { index.item(id) }
    /// All revisions of an item, newest first.
    public func history(of itemId: UUID) -> [ItemRevision] { index.history(of: itemId) }

    // MARK: - Identity (Team, FR-1)

    /// This person's Team identity, or nil before the first use of Team features.
    /// If two offline Macs each created one, the older one wins on every Mac, so
    /// the choice is the same everywhere; the newer one is never used.
    public func identity() throws -> UserIdentity? {
        guard let revs = identityRevisions.values.min(by: { $0[0].id < $1[0].id }), let latest = revs.last else { return nil }
        return try latest.identity()
    }

    /// Returns the existing identity, or creates one with fresh keys.
    @discardableResult
    public func createIdentity(name: String) async throws -> UserIdentity {
        if let existing = try identity() { return existing }
        let rev = IdentityRevision(id: ULID(), identityId: UUID(), name: name, createdAt: Date(),
                                   agreementKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                                   signingKey: Curve25519.Signing.PrivateKey().rawRepresentation)
        try await write(rev)
        return try rev.identity()
    }

    /// A new name keeps the keys (and so the safety code).
    @discardableResult
    public func renameIdentity(_ name: String) async throws -> UserIdentity {
        guard let current = try identity(), var rev = identityRevisions[current.id]?.last else { throw VaultError.io("No identity yet") }
        rev.id = ULID()
        rev.name = name
        try await write(rev)
        return try rev.identity()
    }

    // MARK: - Writing

    @discardableResult
    public func createProject(name: String, tags: [String] = []) async throws -> Project {
        let rev = index.newProject(name: name, tags: tags, device: device)
        try await write(rev)
        return Project(revision: rev, itemCount: 0)
    }

    @discardableResult
    public func updateProject(_ id: UUID, name: String? = nil, tags: [String]? = nil) async throws -> Project {
        let rev = try index.updatedProject(id, name: name, tags: tags, device: device)
        try await write(rev)
        return Project(revision: rev, itemCount: index.liveItems(in: id).count)
    }

    /// Soft-deletes the project and every live item in it (each gets a tombstone).
    public func deleteProject(_ id: UUID) async throws {
        for item in index.liveItems(in: id) { try await deleteItem(item.id) }
        guard let rev = index.deletedProject(id, device: device) else { return }
        try await write(rev)
    }

    @discardableResult
    public func createItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String] = []) async throws -> Item {
        let rev = try index.newItem(in: projectId, name: name, payload: payload, tags: tags, device: device)
        try await write(rev)
        return Item(revision: rev, revisionCount: 1)
    }

    @discardableResult
    public func updateItem(_ id: UUID, name: String? = nil, tags: [String]? = nil, payload: ItemPayload? = nil, projectId: UUID? = nil) async throws -> Item {
        guard let rev = try index.updatedItem(id, name: name, tags: tags, payload: payload, projectId: projectId, device: device) else {
            return index.item(id)!
        }
        try await write(rev)
        return index.current(rev)
    }

    public func deleteItem(_ id: UUID) async throws {
        guard let rev = index.deletedItem(id, device: device) else { return }
        try await write(rev)
    }

    /// Writes a new revision whose content equals an older one (undelete or restore).
    @discardableResult
    public func restore(_ old: ItemRevision) async throws -> Item {
        let rev = index.restored(old, device: device)
        try await write(rev)
        return index.current(rev)
    }

    /// Removes all but the latest revision of an item from storage.
    public func compact(itemId: UUID) async throws {
        for path in index.compact(itemId: itemId) { try await storage.delete(path) }
    }

    public func changePassphrase(current: String, new: String) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        _ = try KeyHierarchy.unlock(header: header, passphrase: current)
        let newHeader = try KeyHierarchy.rewrap(header: header, vaultKey: vk, newPassphrase: new)
        try await storage.writeReplace(VaultPath(VaultHeader.fileName), data: try newHeader.encoded())
        header = newHeader
    }

    // MARK: - Recovery

    public var hasRecoveryKey: Bool { header.recovery != nil }

    /// Creates (or replaces) the recovery key. Show the returned string once.
    public func createRecoveryKey() async throws -> String {
        guard let vk = vaultKey else { throw VaultError.locked }
        let (h, key) = try KeyHierarchy.addRecovery(header: header, vaultKey: vk)
        try await storage.writeReplace(VaultPath(VaultHeader.fileName), data: try h.encoded())
        header = h
        return key
    }

    public func removeRecoveryKey() async throws {
        guard vaultKey != nil else { throw VaultError.locked }
        var h = header
        h.recovery = nil
        try await storage.writeReplace(VaultPath(VaultHeader.fileName), data: try h.encoded())
        header = h
    }

    /// Unlocks with the recovery key. Follow with `resetPassphrase` so the
    /// user has a passphrase again.
    @discardableResult
    public func unlock(recoveryKey: String, progress: Progress? = nil) async throws -> VaultKey {
        let vk = try KeyHierarchy.unlock(header: header, recoveryKey: recoveryKey)
        try await unlock(vaultKey: vk, progress: progress)
        return vk
    }

    /// Sets a new passphrase without knowing the old one (vault must be unlocked,
    /// e.g. via recovery key or Touch ID).
    public func resetPassphrase(new: String) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let newHeader = try KeyHierarchy.rewrap(header: header, vaultKey: vk, newPassphrase: new)
        try await storage.writeReplace(VaultPath(VaultHeader.fileName), data: try newHeader.encoded())
        header = newHeader
    }

    // MARK: - Encoding

    private func write(_ rev: ProjectRevision) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .project, ownerId: rev.projectId, revisionId: rev.id, key: vk)
        let path = RevisionLayout.projectPath(projectId: rev.projectId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        index.insert(rev)
        index.indexedPaths.insert(path.string)
    }

    private func write(_ rev: IdentityRevision) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .identity, ownerId: rev.identityId, revisionId: rev.id, key: vk)
        let path = RevisionLayout.identityPath(identityId: rev.identityId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        RevisionIndex.insert(rev, into: &identityRevisions[rev.identityId, default: []])
        index.indexedPaths.insert(path.string)
    }

    private func write(_ rev: ItemRevision) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        let path = RevisionLayout.itemPath(projectId: rev.projectId, itemId: rev.itemId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        index.insert(rev)
        index.indexedPaths.insert(path.string)
    }
}
