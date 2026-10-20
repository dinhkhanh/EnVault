import Foundation

/// Where a vault's project and item revisions live, and how to find them:
/// ```
/// projects/<projectId>/meta/<ulid>.evr
/// projects/<projectId>/items/<itemId>/<ulid>.evr
/// projects/<IdentityLayout.namespace>/identity/<identityId>/<ulid>.evr   (personal vaults only)
/// projects/<IdentityLayout.namespace>/teams/<vaultId>/<ulid>.evr          (personal vaults only)
/// ```
enum RevisionLayout {
    struct Found: Sendable {
        var path: VaultPath
        var scope: RevisionFile.Scope
        var ownerId: UUID
        var revisionId: ULID
    }

    static func projectPath(projectId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", projectId.uuidString, "meta", fileName(revisionId))
    }
    static func itemPath(projectId: UUID, itemId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", projectId.uuidString, "items", itemId.uuidString, fileName(revisionId))
    }
    static func identityPath(identityId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", IdentityLayout.namespace.uuidString, "identity", identityId.uuidString, fileName(revisionId))
    }
    static func teamPath(vaultId: UUID, revisionId: ULID) -> VaultPath {
        VaultPath("projects", IdentityLayout.namespace.uuidString, "teams", vaultId.uuidString, fileName(revisionId))
    }
    static func fileName(_ id: ULID) -> String { "\(id.string).\(RevisionFile.fileExtension)" }

    static func revisionId(fromFileName name: String) -> ULID? {
        guard name.hasSuffix("." + RevisionFile.fileExtension) else { return nil }
        return ULID(string: String(name.dropLast(RevisionFile.fileExtension.count + 1)))
    }

    /// Every revision file whose path is not in `skipping`.
    static func scan(_ storage: VaultStorage, skipping: Set<String>) async throws -> [Found] {
        var found: [Found] = []
        func add(_ dir: VaultPath, _ scope: RevisionFile.Scope, _ owner: UUID) async throws {
            for file in try await storage.list(dir) {
                let path = dir.appending(file)
                guard !skipping.contains(path.string), let rid = revisionId(fromFileName: file) else { continue }
                found.append(Found(path: path, scope: scope, ownerId: owner, revisionId: rid))
            }
        }
        let projectsDir = VaultPath("projects")
        for pid in try await storage.list(projectsDir) {
            guard let projectId = UUID(uuidString: pid) else { continue }
            let pdir = projectsDir.appending(pid)
            if projectId == IdentityLayout.namespace {
                for (folder, scope) in [("identity", RevisionFile.Scope.identity), ("teams", .team)] {
                    let dir = pdir.appending(folder)
                    for sub in try await storage.list(dir) {
                        guard let owner = UUID(uuidString: sub) else { continue }
                        try await add(dir.appending(sub), scope, owner)
                    }
                }
                continue
            }
            try await add(pdir.appending("meta"), .project, projectId)
            let itemsDir = pdir.appending("items")
            for iid in try await storage.list(itemsDir) {
                guard let itemId = UUID(uuidString: iid) else { continue }
                try await add(itemsDir.appending(iid), .item, itemId)
            }
        }
        return found
    }
}

/// The decrypted project and item revisions of one vault (each list sorted
/// ascending by id), and the read models and next revisions built from them.
/// Shared by `VaultStore` and `TeamVaultStore`, which differ only in how
/// revisions are sealed.
struct RevisionIndex: Sendable {
    private(set) var projectRevisions: [UUID: [ProjectRevision]] = [:]
    private(set) var itemRevisions: [UUID: [ItemRevision]] = [:]
    var indexedPaths: Set<String> = []

    mutating func insert(_ rev: ProjectRevision) {
        Self.insert(rev, into: &projectRevisions[rev.projectId, default: []])
    }

    mutating func insert(_ rev: ItemRevision) {
        Self.insert(rev, into: &itemRevisions[rev.itemId, default: []])
    }

    static func insert<R: Identifiable>(_ rev: R, into list: inout [R]) where R.ID == ULID {
        if let i = list.firstIndex(where: { $0.id >= rev.id }) {
            if list[i].id != rev.id { list.insert(rev, at: i) }
        } else { list.append(rev) }
    }

    /// Keeps only the latest revision of an item; returns the paths of the others.
    mutating func compact(itemId: UUID) -> [VaultPath] {
        guard let revs = itemRevisions[itemId], revs.count > 1, let latest = revs.last else { return [] }
        let paths = revs.dropLast().map { RevisionLayout.itemPath(projectId: $0.projectId, itemId: itemId, revisionId: $0.id) }
        for p in paths { indexedPaths.remove(p.string) }
        itemRevisions[itemId] = [latest]
        return paths
    }

    // MARK: - Reading

    func projects(includeDeleted: Bool = false) -> [Project] {
        projectRevisions.values.compactMap { revs -> Project? in
            guard let latest = revs.last, includeDeleted || !latest.deleted else { return nil }
            return Project(revision: latest, itemCount: liveItems(in: latest.projectId).count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func project(_ id: UUID) -> Project? {
        guard let latest = projectRevisions[id]?.last, !latest.deleted else { return nil }
        return Project(revision: latest, itemCount: liveItems(in: id).count)
    }

    func items(in projectId: UUID) -> [Item] {
        liveItems(in: projectId).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func allItems() -> [Item] {
        itemRevisions.values.compactMap { revs in
            guard let latest = revs.last, !latest.deleted, project(latest.projectId) != nil else { return nil }
            return Item(revision: latest, revisionCount: revs.count)
        }
    }

    func item(_ id: UUID) -> Item? {
        guard let revs = itemRevisions[id], let latest = revs.last, !latest.deleted else { return nil }
        return Item(revision: latest, revisionCount: revs.count)
    }

    /// All revisions of an item, newest first.
    func history(of itemId: UUID) -> [ItemRevision] {
        (itemRevisions[itemId] ?? []).reversed()
    }

    func revisionCount(of itemId: UUID) -> Int { itemRevisions[itemId]?.count ?? 0 }

    /// A live project's revisions and those of its live items, oldest first,
    /// for copying it into another vault.
    func export(_ projectId: UUID) throws -> (history: [ProjectRevision], items: [[ItemRevision]]) {
        guard project(projectId) != nil, let history = projectRevisions[projectId] else { throw VaultError.io("Unknown project") }
        let items = liveItems(in: projectId).sorted { $0.createdAt < $1.createdAt }.compactMap { itemRevisions[$0.id] }
        return (history, items)
    }

    func liveItems(in projectId: UUID) -> [Item] {
        itemRevisions.values.compactMap { revs in
            guard let latest = revs.last, latest.projectId == projectId, !latest.deleted else { return nil }
            return Item(revision: latest, revisionCount: revs.count)
        }
    }

    // MARK: - Next revisions (the caller seals and writes them, then inserts)

    func newProject(name: String, tags: [String], device: DeviceIdentity) -> ProjectRevision {
        let now = Date()
        return ProjectRevision(projectId: UUID(), name: name, tags: tags, createdAt: now, modifiedAt: now, device: device)
    }

    func updatedProject(_ id: UUID, name: String?, tags: [String]?, device: DeviceIdentity) throws -> ProjectRevision {
        guard var rev = projectRevisions[id]?.last else { throw VaultError.io("Unknown project") }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device
        if let name { rev.name = name }
        if let tags { rev.tags = tags }
        return rev
    }

    func deletedProject(_ id: UUID, device: DeviceIdentity) -> ProjectRevision? {
        guard var rev = projectRevisions[id]?.last else { return nil }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = true
        return rev
    }

    func newItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String], device: DeviceIdentity) throws -> ItemRevision {
        guard project(projectId) != nil else { throw VaultError.io("Unknown project") }
        let now = Date()
        return ItemRevision(itemId: UUID(), projectId: projectId, name: name, tags: tags, payload: payload, createdAt: now, modifiedAt: now, device: device)
    }

    /// Nil when nothing would change, so history stays meaningful.
    func updatedItem(_ id: UUID, name: String?, tags: [String]?, payload: ItemPayload?, projectId: UUID?, device: DeviceIdentity) throws -> ItemRevision? {
        guard let last = itemRevisions[id]?.last else { throw VaultError.io("Unknown item") }
        var rev = last
        if let name { rev.name = name }
        if let tags { rev.tags = tags }
        if let payload { rev.payload = payload }
        if let projectId { rev.projectId = projectId }
        if last.name == rev.name, last.tags == rev.tags, last.payload == rev.payload, last.projectId == rev.projectId, !last.deleted {
            return nil
        }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = false
        return rev
    }

    func deletedItem(_ id: UUID, device: DeviceIdentity) -> ItemRevision? {
        guard var rev = itemRevisions[id]?.last, !rev.deleted else { return nil }
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = true
        return rev
    }

    func restored(_ old: ItemRevision, device: DeviceIdentity) -> ItemRevision {
        var rev = old
        rev.id = ULID(); rev.modifiedAt = Date(); rev.device = device; rev.deleted = false
        return rev
    }

    /// The item as it reads after `rev` was inserted.
    func current(_ rev: ItemRevision) -> Item { Item(revision: rev, revisionCount: revisionCount(of: rev.itemId)) }
}
