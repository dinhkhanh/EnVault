import Foundation

/// The single entry point to a vault. Owns the vault key while unlocked,
/// maintains an in-memory index of all revisions, and writes new revisions.
///
/// Layout on storage:
/// ```
/// vault.json
/// projects/<projectId>/meta/<ulid>.evr
/// projects/<projectId>/items/<itemId>/<ulid>.evr
/// ```
public actor VaultStore {
    public let storage: VaultStorage
    public let device: DeviceIdentity
    public private(set) var header: VaultHeader

    private var vaultKey: VaultKey?
    private var projectRevisions: [UUID: [ProjectRevision]] = [:]   // sorted ascending by id
    private var itemRevisions: [UUID: [ItemRevision]] = [:]         // sorted ascending by id
    private var indexedPaths: Set<String> = []

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
        projectRevisions = [:]
        itemRevisions = [:]
        indexedPaths = []
    }

    // MARK: - Indexing

    /// Progress callback for long scans: (revisions decrypted, revisions found).
    public typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    private enum Pending: Sendable {
        case project(VaultPath, ownerId: UUID, revisionId: ULID)
        case item(VaultPath, ownerId: UUID, revisionId: ULID)
        var path: VaultPath { switch self { case .project(let p, _, _), .item(let p, _, _): p } }
    }

    /// Scans storage for revision files not yet indexed and decrypts them.
    /// Files are read in batches: per-file reads dominate, especially in iCloud Drive.
    /// Returns true when anything new was found.
    @discardableResult
    public func refresh(progress: Progress? = nil) async throws -> Bool {
        guard let vk = vaultKey else { throw VaultError.locked }
        var pending: [Pending] = []
        let projectsDir = VaultPath("projects")
        for pid in try await storage.list(projectsDir) {
            guard let projectId = UUID(uuidString: pid) else { continue }
            let pdir = projectsDir.appending(pid)
            for file in try await storage.list(pdir.appending("meta")) {
                let path = pdir.appending("meta").appending(file)
                guard !indexedPaths.contains(path.string), let rid = revisionId(fromFileName: file) else { continue }
                pending.append(.project(path, ownerId: projectId, revisionId: rid))
            }
            let itemsDir = pdir.appending("items")
            for iid in try await storage.list(itemsDir) {
                guard let itemId = UUID(uuidString: iid) else { continue }
                let idir = itemsDir.appending(iid)
                for file in try await storage.list(idir) {
                    let path = idir.appending(file)
                    guard !indexedPaths.contains(path.string), let rid = revisionId(fromFileName: file) else { continue }
                    pending.append(.item(path, ownerId: itemId, revisionId: rid))
                }
            }
        }
        guard !pending.isEmpty else { return false }

        let total = pending.count
        var done = 0
        progress?(0, total)
        for start in stride(from: 0, to: total, by: 100) {
            let batch = Array(pending[start..<min(start + 100, total)])
            let files = try await storage.readMany(batch.map(\.path))
            for (p, data) in zip(batch, files) {
                switch p {
                case .project(let path, let owner, let rid):
                    insert(try RevisionFile.decode(ProjectRevision.self, from: data, vaultId: vaultId, scope: .project, ownerId: owner, revisionId: rid, key: vk))
                    indexedPaths.insert(path.string)
                case .item(let path, let owner, let rid):
                    insert(try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: owner, revisionId: rid, key: vk))
                    indexedPaths.insert(path.string)
                }
            }
            done += batch.count
            progress?(done, total)
        }
        return true
    }

    private func revisionId(fromFileName name: String) -> ULID? {
        guard name.hasSuffix("." + RevisionFile.fileExtension) else { return nil }
        return ULID(string: String(name.dropLast(RevisionFile.fileExtension.count + 1)))
    }

    private func insert(_ rev: ProjectRevision) {
        var list = projectRevisions[rev.projectId] ?? []
        if let i = list.firstIndex(where: { $0.id >= rev.id }) {
            if list[i].id != rev.id { list.insert(rev, at: i) }
        } else { list.append(rev) }
        projectRevisions[rev.projectId] = list
    }

    private func insert(_ rev: ItemRevision) {
        var list = itemRevisions[rev.itemId] ?? []
        if let i = list.firstIndex(where: { $0.id >= rev.id }) {
            if list[i].id != rev.id { list.insert(rev, at: i) }
        } else { list.append(rev) }
        itemRevisions[rev.itemId] = list
    }

    // MARK: - Reading

    public func projects(includeDeleted: Bool = false) -> [Project] {
        projectRevisions.values.compactMap { revs -> Project? in
            guard let latest = revs.last, includeDeleted || !latest.deleted else { return nil }
            return Project(revision: latest, itemCount: liveItems(in: latest.projectId).count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func project(_ id: UUID) -> Project? {
        guard let latest = projectRevisions[id]?.last, !latest.deleted else { return nil }
        return Project(revision: latest, itemCount: liveItems(in: id).count)
    }

    public func items(in projectId: UUID) -> [Item] {
        liveItems(in: projectId).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func allItems() -> [Item] {
        itemRevisions.values.compactMap { revs in
            guard let latest = revs.last, !latest.deleted, project(latest.projectId) != nil else { return nil }
            return Item(revision: latest, revisionCount: revs.count)
        }
    }

    public func item(_ id: UUID) -> Item? {
        guard let revs = itemRevisions[id], let latest = revs.last, !latest.deleted else { return nil }
        return Item(revision: latest, revisionCount: revs.count)
    }

    /// All revisions of an item, newest first.
    public func history(of itemId: UUID) -> [ItemRevision] {
        (itemRevisions[itemId] ?? []).reversed()
    }

    private func liveItems(in projectId: UUID) -> [Item] {
        itemRevisions.values.compactMap { revs in
            guard let latest = revs.last, latest.projectId == projectId, !latest.deleted else { return nil }
            return Item(revision: latest, revisionCount: revs.count)
        }
    }

    // MARK: - Writing

    @discardableResult
    public func createProject(name: String, tags: [String] = []) async throws -> Project {
        let now = Date()
        let rev = ProjectRevision(projectId: UUID(), name: name, tags: tags, createdAt: now, modifiedAt: now, device: device)
        try await write(rev)
        return Project(revision: rev, itemCount: 0)
    }

    @discardableResult
    public func updateProject(_ id: UUID, name: String? = nil, tags: [String]? = nil) async throws -> Project {
        guard var rev = projectRevisions[id]?.last else { throw VaultError.io("Unknown project") }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device
        if let name { rev.name = name }
        if let tags { rev.tags = tags }
        try await write(rev)
        return Project(revision: rev, itemCount: liveItems(in: id).count)
    }

    /// Soft-deletes the project and every live item in it (each gets a tombstone).
    public func deleteProject(_ id: UUID) async throws {
        for item in liveItems(in: id) { try await deleteItem(item.id) }
        guard var rev = projectRevisions[id]?.last else { return }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = true
        try await write(rev)
    }

    @discardableResult
    public func createItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String] = []) async throws -> Item {
        guard project(projectId) != nil else { throw VaultError.io("Unknown project") }
        let now = Date()
        let rev = ItemRevision(itemId: UUID(), projectId: projectId, name: name, tags: tags, payload: payload, createdAt: now, modifiedAt: now, device: device)
        try await write(rev)
        return Item(revision: rev, revisionCount: 1)
    }

    @discardableResult
    public func updateItem(_ id: UUID, name: String? = nil, tags: [String]? = nil, payload: ItemPayload? = nil, projectId: UUID? = nil) async throws -> Item {
        guard var rev = itemRevisions[id]?.last else { throw VaultError.io("Unknown item") }
        if let name { rev.name = name }
        if let tags { rev.tags = tags }
        if let payload { rev.payload = payload }
        if let projectId { rev.projectId = projectId }
        // Skip no-op saves so history stays meaningful.
        if let last = itemRevisions[id]?.last, last.name == rev.name, last.tags == rev.tags, last.payload == rev.payload, last.projectId == rev.projectId, !last.deleted {
            return Item(revision: last, revisionCount: itemRevisions[id]!.count)
        }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = false
        try await write(rev)
        return Item(revision: rev, revisionCount: itemRevisions[id]!.count)
    }

    public func deleteItem(_ id: UUID) async throws {
        guard var rev = itemRevisions[id]?.last, !rev.deleted else { return }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = true
        try await write(rev)
    }

    /// Writes a new revision whose content equals an older one (undelete or restore).
    @discardableResult
    public func restore(_ old: ItemRevision) async throws -> Item {
        var rev = old
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = false
        try await write(rev)
        return Item(revision: rev, revisionCount: itemRevisions[rev.itemId]!.count)
    }

    /// Removes all but the latest revision of an item from storage.
    public func compact(itemId: UUID) async throws {
        guard let revs = itemRevisions[itemId], revs.count > 1, let latest = revs.last else { return }
        for old in revs.dropLast() {
            let path = itemPath(projectId: old.projectId, itemId: itemId, revisionId: old.id)
            try await storage.delete(path)
            indexedPaths.remove(path.string)
        }
        itemRevisions[itemId] = [latest]
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

    // MARK: - Paths & encoding

    private func itemPath(projectId: UUID, itemId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", projectId.uuidString, "items", itemId.uuidString, "\(revisionId.string).\(RevisionFile.fileExtension)")
    }
    private func projectPath(projectId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", projectId.uuidString, "meta", "\(revisionId.string).\(RevisionFile.fileExtension)")
    }

    private func write(_ rev: ProjectRevision) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .project, ownerId: rev.projectId, revisionId: rev.id, key: vk)
        let path = projectPath(projectId: rev.projectId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        insert(rev)
        indexedPaths.insert(path.string)
    }

    private func write(_ rev: ItemRevision) async throws {
        guard let vk = vaultKey else { throw VaultError.locked }
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        let path = itemPath(projectId: rev.projectId, itemId: rev.itemId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        insert(rev)
        indexedPaths.insert(path.string)
    }
}
