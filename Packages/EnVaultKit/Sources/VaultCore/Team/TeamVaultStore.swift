import Foundation
import CryptoKit

/// Where this person stands in a team vault.
public enum TeamAccess: Equatable, Sendable {
    case locked
    /// Not in the membership log: waiting for an admin's approval (FR-7).
    case notMember
    /// Approved, but no copy of the newest key has arrived yet.
    case awaitingKey(TeamRole)
    case member(TeamRole)
    case removed
}

/// One person in a team vault, as the app shows them.
public struct TeamMember: Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Nil until a key that opens it is available.
    public var name: String?
    public var role: TeamRole
    public var safetyCode: String
}

/// What `maintain()` wrote.
public struct TeamRepair: Equatable, Sendable {
    /// The epoch a rotation started, when one was needed.
    public var rotated: ULID?
    /// Members given a missing copy of the current key.
    public var wraps: [UUID] = []
    /// Older epochs linked from the current one.
    public var links: [ULID] = []
    public var isEmpty: Bool { rotated == nil && wraps.isEmpty && links.isEmpty }
}

/// A team vault (format 2): the same projects and items as a personal vault,
/// sealed under the team's epoch keys and signed by their authors.
///
/// Layout on storage:
/// ```
/// vault.json                         TeamHeader, written once by the owner
/// members/<ulid>.json                MembershipEvent
/// keys/<epoch>/<memberId>.json       KeyWrap
/// keys/<epoch>/prev-<epoch>.json     KeyLink
/// identities/<memberId>/<ulid>.json  JoinRequest
/// projects/<projectId>/…/<ulid>.evr  TeamRevisionFile, laid out as in a personal vault
/// ```
/// Unlocking takes the person's identity from their personal vault. Files
/// that fail a check are left out and listed in `rejectedFiles` (FR-18).
public actor TeamVaultStore {
    public let storage: VaultStorage
    public let device: DeviceIdentity
    public nonisolated let header: TeamHeader
    public nonisolated var vaultId: UUID { header.vaultId }

    private var me: UserIdentity?
    public private(set) var state: TeamState
    private var events: [ULID: MembershipEvent] = [:]
    /// Events known before this session (the app keeps them between launches).
    private var seen: Set<ULID> = []
    private var keys: [ULID: SymmetricKey] = [:]
    private var wrapsPresent: [ULID: Set<UUID>] = [:]
    private var linksPresent: [ULID: Set<ULID>] = [:]   // newer epoch → older epochs
    private var index = RevisionIndex()
    private var authors: [ULID: UUID] = [:]
    /// The epoch each indexed revision is sealed under.
    private var revisionEpochs: [ULID: ULID] = [:]
    /// The event set the index was checked against; a change re-checks every revision.
    private var indexedEvents: Set<ULID>?
    /// Revisions sealed under an epoch whose key this Mac does not hold yet.
    private var waitingForKey: [String: ULID] = [:]
    /// Each requester's newest valid join request.
    private var requests: [UUID: JoinRequest] = [:]
    private var requestPaths: Set<String> = []
    /// Paths ignored, with the reason.
    public private(set) var rejectedFiles: [String: String] = [:]
    /// Membership changes that arrived after newer ones were already applied.
    /// Honest offline admins cause these too, but so would a removed admin
    /// backdating a change, so an admin reviews them.
    public private(set) var lateEvents: Set<ULID> = []

    static let membersDir = VaultPath("members")
    static let keysDir = VaultPath("keys")
    static let requestsDir = VaultPath("identities")

    private init(storage: VaultStorage, header: TeamHeader, device: DeviceIdentity) {
        self.storage = storage
        self.header = header
        self.device = device
        state = TeamState(header: header, events: [])
    }

    // MARK: - Lifecycle

    /// Creates a team vault at an empty location, owned by `owner`, and
    /// returns it unlocked with its first key epoch (FR-3).
    public static func create(storage: VaultStorage, owner: UserIdentity, title: String, vaultId: UUID = UUID(), device: DeviceIdentity = .current()) async throws -> TeamVaultStore {
        let path = VaultPath(VaultHeader.fileName)
        if try await storage.exists(path) { throw VaultError.vaultAlreadyExists }
        let header = try TeamHeader.create(owner: owner, vaultId: vaultId)
        try await storage.writeNew(path, data: try header.encoded())
        let store = TeamVaultStore(storage: storage, header: header, device: device)
        try await store.unlock(identity: owner)
        try await store.rotate()
        try await store.setName(owner.name)
        try await store.setTitle(title)
        return store
    }

    /// Opens a team vault, locked. `owner` is the owner's signing key as first
    /// seen on this Mac: the header is never replaced, so a different one means
    /// someone swapped it.
    public static func open(storage: VaultStorage, device: DeviceIdentity = .current(), owner: Data? = nil) async throws -> TeamVaultStore {
        let path = VaultPath(VaultHeader.fileName)
        guard try await storage.exists(path) else { throw VaultError.noVaultAtLocation }
        let header = try TeamHeader.decode(try await storage.read(path))
        if let owner, header.owner.signingKey != owner { throw VaultError.corruptHeader("the team vault's owner changed") }
        return TeamVaultStore(storage: storage, header: header, device: device)
    }

    /// Unlocks with the person's identity. `seenEvents` are the membership
    /// events this Mac had already applied (`knownEvents` from last time);
    /// anything older that turns up now is flagged in `lateEvents`.
    @discardableResult
    public func unlock(identity: UserIdentity, seenEvents: Set<ULID> = []) async throws -> TeamAccess {
        me = identity
        seen = seenEvents
        do { try await refresh() } catch { lock(); throw error }
        return access
    }

    public func lock() {
        me = nil
        seen = []
        events = [:]
        state = TeamState(header: header, events: [])
        keys = [:]
        wrapsPresent = [:]
        linksPresent = [:]
        index = RevisionIndex()
        authors = [:]
        revisionEpochs = [:]
        indexedEvents = nil
        waitingForKey = [:]
        requests = [:]
        requestPaths = []
        rejectedFiles = [:]
        lateEvents = []
    }

    public var isUnlocked: Bool { me != nil }

    public var access: TeamAccess {
        guard let me else { return .locked }
        if let role = state.role(of: me.id) {
            if let e = state.current, keys[e.id] != nil { return .member(role) }
            return .awaitingKey(role)
        }
        return state.everyone[me.id] != nil ? .removed : .notMember
    }

    /// Every membership event applied, to pass back as `seenEvents` next time.
    public var knownEvents: Set<ULID> { Set(events.keys) }

    /// The admin has looked at these late events.
    public func dismissLate(_ ids: Set<ULID>) { lateEvents.subtract(ids) }

    // MARK: - Indexing

    /// Reads new membership events, key copies and revisions. Returns true
    /// when anything changed.
    @discardableResult
    public func refresh() async throws -> Bool {
        guard let me else { throw VaultError.locked }
        let membership = try await loadEvents()
        let gotKeys = try await loadKeys(for: me)
        let revisions = try await loadRevisions()
        let asked = try await loadRequests()
        return membership || gotKeys || revisions || asked
    }

    private func loadRequests() async throws -> Bool {
        var fresh: [(VaultPath, UUID)] = []
        for dir in try await storage.list(Self.requestsDir) {
            guard let member = UUID(uuidString: dir) else { continue }
            for file in try await storage.list(Self.requestsDir.appending(dir)) where file.hasSuffix(".json") {
                let path = Self.requestsDir.appending(dir).appending(file)
                guard !requestPaths.contains(path.string), rejectedFiles[path.string] == nil else { continue }
                fresh.append((path, member))
            }
        }
        guard !fresh.isEmpty else { return false }
        var changed = false
        for ((path, member), data) in zip(fresh, try await storage.readMany(fresh.map(\.0))) {
            guard let r = try? JoinRequest.decode(data), r.identity.id == member, path.lastComponent == "\(r.id.string).json",
                  r.isValid(vaultId: vaultId) else {
                rejectedFiles[path.string] = "invalid join request"
                continue
            }
            requestPaths.insert(path.string)
            if let old = requests[member], old.id > r.id { continue }
            requests[member] = r
            changed = true
        }
        return changed
    }

    private func loadEvents() async throws -> Bool {
        let dir = Self.membersDir
        let known = Set(events.keys)
        var fresh: [(VaultPath, ULID)] = []
        for name in try await storage.list(dir) {
            let path = dir.appending(name)
            guard rejectedFiles[path.string] == nil, name.hasSuffix(".json"),
                  let id = ULID(string: String(name.dropLast(5))), !known.contains(id) else { continue }
            fresh.append((path, id))
        }
        guard !fresh.isEmpty else { return false }
        var added: [ULID] = []
        for ((path, id), data) in zip(fresh, try await storage.readMany(fresh.map(\.0))) {
            guard let e = try? MembershipEvent.decode(data), e.id == id else {
                rejectedFiles[path.string] = "unreadable membership event"
                continue
            }
            events[id] = e
            added.append(id)
        }
        guard !added.isEmpty else { return false }
        state = TeamState(header: header, events: Array(events.values))
        let before = known.union(seen)
        if let newest = before.max() {
            for id in added where id < newest && !before.contains(id) && state.rejected[id] == nil { lateEvents.insert(id) }
        }
        return true
    }

    /// Lists every epoch's key files, unwraps this person's copies and follows
    /// links back to older epochs.
    private func loadKeys(for me: UserIdentity) async throws -> Bool {
        let before = keys.count
        let mine = "\(me.id.uuidString).json"
        for name in try await storage.list(Self.keysDir) {
            guard let epochId = ULID(string: name) else { continue }
            let dir = Self.keysDir.appending(name)
            for file in try await storage.list(dir) {
                if file.hasPrefix("prev-"), file.hasSuffix(".json"), let older = ULID(string: String(file.dropFirst(5).dropLast(5))) {
                    linksPresent[epochId, default: []].insert(older)
                } else if file.hasSuffix(".json"), let member = UUID(uuidString: String(file.dropLast(5))) {
                    wrapsPresent[epochId, default: []].insert(member)
                }
            }
            let path = dir.appending(mine)
            guard keys[epochId] == nil, wrapsPresent[epochId]?.contains(me.id) == true,
                  rejectedFiles[path.string] == nil, let epoch = state.epoch(epochId) else { continue }
            do {
                keys[epochId] = try TeamKeys.unwrap(try KeyWrap.decode(try await storage.read(path)), identity: me, vaultId: vaultId, epoch: epoch)
            } catch {
                rejectedFiles[path.string] = error.localizedDescription
            }
        }
        // Follow links until no new key turns up.
        var progress = true
        while progress {
            progress = false
            for (newer, olders) in linksPresent {
                guard let newerKey = keys[newer] else { continue }
                for older in olders where keys[older] == nil {
                    let path = Self.keysDir.appending(newer.string).appending("prev-\(older.string).json")
                    guard rejectedFiles[path.string] == nil, let epoch = state.epoch(older) else { continue }
                    do {
                        keys[older] = try TeamKeys.open(try KeyLink.decode(try await storage.read(path)), with: newerKey, older: epoch, vaultId: vaultId)
                        progress = true
                    } catch {
                        rejectedFiles[path.string] = error.localizedDescription
                    }
                }
            }
        }
        return keys.count != before
    }

    private func loadRevisions() async throws -> Bool {
        var changed = false
        // A membership change can change who was allowed to write when, so
        // every revision is checked again.
        let eventIds = Set(events.keys)
        if indexedEvents != eventIds {
            changed = indexedEvents != nil && !index.indexedPaths.isEmpty
            index = RevisionIndex()
            authors = [:]
            revisionEpochs = [:]
            waitingForKey = [:]
            rejectedFiles = rejectedFiles.filter { !$0.key.hasPrefix("projects/") }
            indexedEvents = eventIds
        }
        let skip = index.indexedPaths.union(rejectedFiles.keys)
            .union(waitingForKey.filter { keys[$0.value] == nil }.keys)
        let found = try await RevisionLayout.scan(storage, skipping: skip)
        guard !found.isEmpty else { return changed }
        for start in stride(from: 0, to: found.count, by: 100) {
            let batch = Array(found[start..<min(start + 100, found.count)])
            for (f, data) in zip(batch, try await storage.readMany(batch.map(\.path))) {
                let path = f.path.string
                guard let epoch = TeamRevisionFile.epoch(of: data) else {
                    rejectedFiles[path] = "not a team revision"
                    continue
                }
                guard keys[epoch] != nil else {
                    waitingForKey[path] = epoch
                    continue
                }
                waitingForKey[path] = nil
                do {
                    switch f.scope {
                    case .project:
                        let (rev, author) = try TeamRevisionFile.decode(ProjectRevision.self, from: data, vaultId: vaultId, scope: .project, ownerId: f.ownerId,
                                                                        revisionId: f.revisionId, state: state, keys: keys)
                        guard rev.id == f.revisionId, rev.projectId == f.ownerId else { throw VaultError.corruptRevision("revision does not match its path") }
                        index.insert(rev)
                        authors[rev.id] = author
                        revisionEpochs[rev.id] = epoch
                    case .item:
                        let (rev, author) = try TeamRevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: f.ownerId,
                                                                        revisionId: f.revisionId, state: state, keys: keys)
                        guard rev.id == f.revisionId, rev.itemId == f.ownerId else { throw VaultError.corruptRevision("revision does not match its path") }
                        index.insert(rev)
                        authors[rev.id] = author
                        revisionEpochs[rev.id] = epoch
                    case .identity, .team:
                        throw VaultError.corruptRevision("only a personal vault holds this")
                    }
                    index.indexedPaths.insert(path)
                    changed = true
                } catch {
                    rejectedFiles[path] = error.localizedDescription
                }
            }
        }
        return changed
    }

    // MARK: - Reading

    public func projects(includeDeleted: Bool = false) -> [Project] { index.projects(includeDeleted: includeDeleted).filter { visible(project: $0.id) } }
    public func project(_ id: UUID) -> Project? { visible(project: id) ? index.project(id) : nil }
    public func items(in projectId: UUID) -> [Item] { visible(project: projectId) ? index.items(in: projectId).filter(visible) : [] }
    public func allItems() -> [Item] { index.allItems().filter(visible) }
    public func item(_ id: UUID) -> Item? { index.item(id).flatMap { visible($0) ? $0 : nil } }
    /// All revisions of an item, newest first.
    public func history(of itemId: UUID) -> [ItemRevision] { item(itemId) == nil && hidesHumansOnly ? [] : index.history(of: itemId) }
    public func export(_ projectId: UUID) throws -> (history: [ProjectRevision], items: [[ItemRevision]]) {
        guard visible(project: projectId) else { throw VaultError.io("Unknown project") }
        return try index.export(projectId)
    }

    // MARK: - Humans only (FR-24)

    /// Set by the command line when an AI agent runs it: humans-only projects
    /// and items are then neither listed, read nor changed.
    public private(set) var hidesHumansOnly = false
    public func hideHumansOnly() { hidesHumansOnly = true }

    public func isHumansOnly(_ id: UUID) -> Bool { state.humansOnly.contains(id) }

    /// Whether a project (and item) by these names exists but is hidden as humans only,
    /// so the command line can say so instead of "not found".
    public func isHiddenAsHumansOnly(project: String, item: String?) -> Bool {
        guard hidesHumansOnly, let p = index.projects().first(where: { $0.name == project }) else { return false }
        if state.humansOnly.contains(p.id) { return true }
        guard let item else { return false }
        return index.items(in: p.id).contains { $0.name == item && state.humansOnly.contains($0.id) }
    }

    private func visible(project id: UUID) -> Bool { !hidesHumansOnly || !state.humansOnly.contains(id) }
    private func visible(_ item: Item) -> Bool {
        !hidesHumansOnly || !(state.humansOnly.contains(item.id) || state.humansOnly.contains(item.projectId))
    }

    /// Refuses a change to something an agent may not touch.
    private func checkVisible(project: UUID?, item: UUID?) throws {
        guard hidesHumansOnly else { return }
        if let project, state.humansOnly.contains(project) { throw VaultError.notPermitted("That project is for people only.") }
        if let item, let i = index.item(item), !visible(i) { throw VaultError.notPermitted("That item is for people only.") }
    }

    public func setHumansOnly(_ id: UUID, _ on: Bool) async throws {
        try await record(.humansOnly(target: id, on: on))
    }

    public func setAgentRules(_ rules: TeamAgentRules) async throws {
        try await record(.agentRules(rules))
    }

    /// Who wrote a revision (FR-19).
    public func author(of revision: ULID) -> UUID? { authors[revision] }

    // MARK: - Exposure after removal (FR-14)

    /// Former members, each with the newest epoch they held a key for. With
    /// it they could open that epoch and, through its links, every older one.
    private func formerHolders() -> [UUID: ULID] {
        var newest: [UUID: ULID] = [:]
        for id in state.everyone.keys where state.members[id] == nil {
            if let e = state.epochs.last(where: { $0.holders.contains(id) }) { newest[id] = e.id }
        }
        return newest
    }

    /// The people no longer in the vault who could read this revision.
    public func formerReaders(of revision: ULID) -> Set<UUID> {
        guard let epoch = revisionEpochs[revision] else { return [] }
        return Set(formerHolders().filter { epoch <= $0.value }.keys)
    }

    /// Live items whose current version people who left could read: the
    /// secrets to rotate, with who could read each (FR-14). An item drops off
    /// once it is saved again under a newer key.
    public func exposedItems() -> [(item: Item, readers: Set<UUID>)] {
        let holders = formerHolders()
        guard !holders.isEmpty else { return [] }
        return index.allItems().compactMap { item in
            guard let epoch = revisionEpochs[item.revisionId] else { return nil }
            let readers = Set(holders.filter { epoch <= $0.value }.keys)
            return readers.isEmpty ? nil : (item, readers)
        }
        .sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    // MARK: - Membership log (FR-19)

    /// Every membership change, newest first, with join requests among them.
    public func log() -> [TeamLogEntry] {
        var out: [TeamLogEntry] = events.values.map { e in
            let change: TeamLogEntry.Change = switch e.change {
            case .add(let identity, let role): .added(identity.id, role)
            case .setRole(let member, let role): .roleChanged(member, role)
            case .remove(let member): member == e.author ? .left(member) : .removed(member)
            case .rotate: .rotated
            case .name(let member, _): .named(member)
            case .title: .titled
            case .agentRules(let r): .agentRules(r)
            case .humansOnly(let target, let on): .humansOnly(target, on)
            case .invite(_, let role, _): .invited(role)
            case .transferOwnership(let to): .ownershipTransferred(to)
            case .license: .licensed
            }
            return TeamLogEntry(id: e.id, author: e.author, change: change, rejected: state.rejected[e.id], late: lateEvents.contains(e.id))
        }
        out += requests.values.map { TeamLogEntry(id: $0.id, author: $0.identity.id, change: .asked($0.identity.id), rejected: nil, late: false) }
        return out.sorted { $0.id > $1.id }
    }

    /// Current members, owner first, then by role and name.
    public func members() -> [TeamMember] {
        state.members.values.map { m in
            TeamMember(id: m.identity.id, name: name(of: m.identity.id), role: m.role, safetyCode: m.identity.safetyCode)
        }
        .sorted { a, b in
            a.role != b.role ? a.role > b.role : (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
        }
    }

    /// A member's name, also for people who have since left.
    public func name(of member: UUID) -> String? {
        guard let n = state.names[member], let key = keys[n.epoch] else { return nil }
        return TeamKeys.open(n, member: member, vaultId: vaultId, key: key)
    }

    /// The vault's display name.
    public var title: String? {
        guard let t = state.title, let key = keys[t.epoch] else { return nil }
        return TeamKeys.open(t, member: vaultId, vaultId: vaultId, key: key)
    }

    // MARK: - Writing content

    @discardableResult
    public func createProject(name: String, tags: [String] = []) async throws -> Project {
        // An agent must not get around a humans-only project by making its twin.
        if hidesHumansOnly, index.projects().contains(where: { $0.name == name && state.humansOnly.contains($0.id) }) {
            throw VaultError.notPermitted("That project is for people only.")
        }
        let rev = index.newProject(name: name, tags: tags, device: device)
        try await write(rev)
        return Project(revision: rev, itemCount: 0)
    }

    @discardableResult
    public func updateProject(_ id: UUID, name: String? = nil, tags: [String]? = nil) async throws -> Project {
        try checkVisible(project: id, item: nil)
        let rev = try index.updatedProject(id, name: name, tags: tags, device: device)
        try await write(rev)
        return Project(revision: rev, itemCount: index.liveItems(in: id).count)
    }

    /// Soft-deletes the project and every live item in it.
    public func deleteProject(_ id: UUID) async throws {
        _ = try writer()
        try checkVisible(project: id, item: nil)
        for item in index.liveItems(in: id) { try await deleteItem(item.id) }
        guard let rev = index.deletedProject(id, device: device) else { return }
        try await write(rev)
    }

    @discardableResult
    public func createItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String] = []) async throws -> Item {
        try checkVisible(project: projectId, item: nil)
        if hidesHumansOnly, index.items(in: projectId).contains(where: { $0.name == name && state.humansOnly.contains($0.id) }) {
            throw VaultError.notPermitted("That item is for people only.")
        }
        let rev = try index.newItem(in: projectId, name: name, payload: payload, tags: tags, device: device)
        try await write(rev)
        return Item(revision: rev, revisionCount: 1)
    }

    @discardableResult
    public func updateItem(_ id: UUID, name: String? = nil, tags: [String]? = nil, payload: ItemPayload? = nil, projectId: UUID? = nil) async throws -> Item {
        try checkVisible(project: projectId, item: id)
        guard let rev = try index.updatedItem(id, name: name, tags: tags, payload: payload, projectId: projectId, device: device) else {
            return index.item(id)!
        }
        try await write(rev)
        return index.current(rev)
    }

    public func deleteItem(_ id: UUID) async throws {
        try checkVisible(project: nil, item: id)
        guard let rev = index.deletedItem(id, device: device) else { return }
        try await write(rev)
    }

    @discardableResult
    public func restore(_ old: ItemRevision) async throws -> Item {
        try checkVisible(project: old.projectId, item: old.itemId)
        let rev = index.restored(old, device: device)
        try await write(rev)
        return index.current(rev)
    }

    /// The identity, epoch and key new revisions are written with.
    private func writer() throws -> (me: UserIdentity, epoch: ULID, key: SymmetricKey) {
        guard let me else { throw VaultError.locked }
        guard let role = state.role(of: me.id), role.canWrite else {
            throw VaultError.notPermitted("Your role in this team vault cannot change secrets.")
        }
        guard !state.needsRotation else {
            throw VaultError.notPermitted("Someone was removed from this team vault. An admin's Mac must rotate the key before anyone saves new secrets.")
        }
        guard let e = state.current, let key = keys[e.id] else {
            throw VaultError.notPermitted("This Mac has not received the team vault's newest key yet.")
        }
        return (me, e.id, key)
    }

    private func write(_ rev: ProjectRevision) async throws {
        let w = try writer()
        let data = try TeamRevisionFile.encode(rev, vaultId: vaultId, scope: .project, ownerId: rev.projectId, revisionId: rev.id, epoch: w.epoch, key: w.key, author: w.me)
        let path = RevisionLayout.projectPath(projectId: rev.projectId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        index.insert(rev)
        index.indexedPaths.insert(path.string)
        authors[rev.id] = w.me.id
        revisionEpochs[rev.id] = w.epoch
    }

    private func write(_ rev: ItemRevision) async throws {
        let w = try writer()
        let data = try TeamRevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, epoch: w.epoch, key: w.key, author: w.me)
        let path = RevisionLayout.itemPath(projectId: rev.projectId, itemId: rev.itemId, revisionId: rev.id)
        try await storage.writeNew(path, data: data)
        index.insert(rev)
        index.indexedPaths.insert(path.string)
        authors[rev.id] = w.me.id
        revisionEpochs[rev.id] = w.epoch
    }

    // MARK: - Joining (FR-7, FR-8)

    /// Asks to join: writes a signed request with this person's name sealed to
    /// the vault's current owner and admins. Safe to repeat; the newest counts.
    public func requestToJoin(invite: ULID? = nil) async throws {
        guard let me else { throw VaultError.locked }
        guard state.role(of: me.id) == nil else { return }
        let managers = state.members.values.filter { $0.role.canManage }.map(\.identity)
        let r = try JoinRequest.signed(by: me, managers: managers, vaultId: vaultId, invite: invite)
        let path = Self.requestsDir.appending(me.id.uuidString).appending("\(r.id.string).json")
        try await storage.writeNew(path, data: try r.encoded())
        requests[me.id] = r
        requestPaths.insert(path.string)
    }

    /// Join requests from people who are not members, newest first. A request
    /// made before the person was last removed no longer counts.
    public func pendingMembers() -> [PendingMember] {
        requests.values.compactMap { r -> PendingMember? in
            let id = r.identity.id
            guard state.members[id] == nil else { return nil }
            if let removed = state.removedAt[id], r.id < removed { return nil }
            var p = PendingMember(request: r.id, identity: r.identity, name: me.flatMap { r.name(for: $0, vaultId: vaultId) })
            if let invite = r.invite {
                let offer = state.invites[invite]
                p.invitedAs = offer?.role
                // Asked after the invitation lapsed, or named one that doesn't exist.
                p.inviteLapsed = offer.map { r.id.timestamp > $0.expiresAt } ?? true
            }
            return p
        }
        .sorted { $0.request > $1.request }
    }

    /// A person's newest join request and where it is stored, so the owner's
    /// Mac can look up who uploaded it and match them to their share participant (FR-12).
    public func joinRequest(of member: UUID) -> (id: ULID, path: String)? {
        guard let r = requests[member] else { return nil }
        return (r.id, Self.requestsDir.appending(member.uuidString).appending("\(r.id.string).json").string)
    }

    /// Invites someone by file (folder mode, FR-6): signs the offer of `role`
    /// for `days`, and returns the file to send them.
    public func createInvite(role: TeamRole, days: Int = 7) async throws -> TeamInvite {
        let id = ULID()
        let expires = Int64(Date().addingTimeInterval(TimeInterval(days) * 86_400).timeIntervalSince1970)
        try await record(.invite(id: id, role: role, expires: expires))
        return TeamInvite(vaultId: vaultId, ownerKey: header.owner.signingKey, invite: id, title: title)
    }

    /// Whether this person has a request waiting.
    public var hasRequestedToJoin: Bool {
        guard let me, let r = requests[me.id] else { return false }
        if let removed = state.removedAt[me.id], r.id < removed { return false }
        return state.members[me.id] == nil
    }

    // MARK: - Copying projects in (FR-5)

    /// Copies a project and its items, every revision in order, into this
    /// vault. Revisions get new ids (they are signed by the person copying, who
    /// could not have written here back then); their dates and contents stay.
    /// Returns the new project's id.
    @discardableResult
    public func importProject(_ history: [ProjectRevision], items: [[ItemRevision]]) async throws -> UUID {
        _ = try writer()
        let projectId = UUID()
        for var rev in history {
            rev.id = ULID(); rev.projectId = projectId; rev.device = device
            try await write(rev)
        }
        for revs in items {
            let itemId = UUID()
            for var rev in revs {
                rev.id = ULID(); rev.itemId = itemId; rev.projectId = projectId; rev.device = device
                try await write(rev)
            }
        }
        return projectId
    }

    // MARK: - Membership

    /// Approves someone who asked to join (FR-8): the add event, a copy of the
    /// current key, and their name sealed under it. The admin has compared
    /// the safety code first.
    public func add(_ person: PublicIdentity, name: String, role: TeamRole) async throws {
        if state.needsRotation { try await rotate() }
        let (epoch, key) = try currentKey()
        try await record(.add(identity: person.unnamed, role: role))
        try await writeWrap(key, epoch: epoch, for: person)
        try await record(.name(member: person.id, name: TeamKeys.seal(name: name, member: person.id, vaultId: vaultId, epoch: epoch, key: key)))
    }

    public func setRole(of member: UUID, to role: TeamRole) async throws {
        try await record(.setRole(member: member, role: role))
    }

    /// Removes a member and rotates the key so they cannot read anything saved
    /// afterwards (FR-13).
    public func remove(_ member: UUID) async throws {
        try await record(.remove(member: member))
        try await rotate()
    }

    /// The owner puts the team's license in the vault (FR-28): the vault
    /// entitlement from their Team key, and how many people use seats in their
    /// other team vaults (seats count people across all of them).
    public func setLicense(_ license: TeamVaultLicense) async throws {
        let (epoch, teamKey) = try currentKey()
        let json = String(decoding: try JSONEncoder().encode(license), as: UTF8.self)
        try await record(.license(TeamKeys.seal(name: json, member: Self.licenseSlot, vaultId: vaultId, epoch: epoch, key: teamKey)))
    }

    /// The license the owner put in the vault, opened with the team key.
    public var license: TeamVaultLicense? {
        guard let l = state.license, let key = keys[l.epoch],
              let json = TeamKeys.open(l, member: Self.licenseSlot, vaultId: vaultId, key: key) else { return nil }
        return try? JSONDecoder().decode(TeamVaultLicense.self, from: Data(json.utf8))
    }

    /// Binds a sealed license to its role, apart from member names and the title.
    static let licenseSlot = UUID(uuidString: "00000000-0000-4000-8000-11ce05e00001")!

    /// Hands ownership to an admin (FR-29); this person becomes an admin.
    public func transferOwnership(to member: UUID) async throws {
        try await record(.transferOwnership(to: member))
    }

    /// Exports the vault as a new personal vault under `passphrase` (FR-30):
    /// every live project with its history, re-encrypted. Owner or admin.
    @discardableResult
    public func exportAsPersonalVault(to storage: VaultStorage, passphrase: String, kdf: KDFParams = .random()) async throws -> VaultStore {
        guard let me, state.role(of: me.id)?.canManage == true else {
            throw VaultError.notPermitted("Only an owner or admin exports a team vault.")
        }
        let personal = try await VaultStore.create(storage: storage, passphrase: passphrase, device: device, kdf: kdf)
        for p in index.projects() {
            let e = try index.export(p.id)
            try await personal.importProject(e.history, items: e.items)
        }
        return personal
    }

    /// Leaves the vault (FR-15). An admin's Mac rotates the key afterwards.
    public func leave() async throws {
        guard let me else { throw VaultError.locked }
        try await record(.remove(member: me.id))
    }

    /// This person's own removal of themselves, if they left (on any Mac).
    public var leaveEvent: ULID? {
        guard let me, let id = state.removedAt[me.id], events[id]?.author == me.id else { return nil }
        return id
    }

    /// Sets this person's own name in the vault.
    public func setName(_ name: String) async throws {
        guard let me else { throw VaultError.locked }
        let (epoch, key) = try currentKey()
        try await record(.name(member: me.id, name: TeamKeys.seal(name: name, member: me.id, vaultId: vaultId, epoch: epoch, key: key)))
    }

    public func setTitle(_ title: String) async throws {
        let (epoch, key) = try currentKey()
        try await record(.title(TeamKeys.seal(name: title, member: vaultId, vaultId: vaultId, epoch: epoch, key: key)))
    }

    /// Starts a new key epoch for every current member and links it to the
    /// older keys this Mac holds. The rotating admin's own copy is written
    /// first, so the key survives a crash halfway through.
    @discardableResult
    public func rotate() async throws -> ULID {
        guard let me else { throw VaultError.locked }
        guard state.role(of: me.id)?.canManage == true else { throw VaultError.notPermitted("Only an owner or admin rotates the team key.") }
        let id = ULID()
        let key = TeamKeys.newKey()
        let recipients = state.members.values.map(\.identity)
        try await writeWrap(key, epoch: id, for: try me.publicIdentity())
        try await record(.rotate(recipients: recipients.map(\.id), keyCommitment: TeamKeys.commitment(to: key, vaultId: vaultId, epoch: id)), id: id)
        keys[id] = key
        for r in recipients where r.id != me.id { try await writeWrap(key, epoch: id, for: r) }
        _ = try await linkMissing()
        return id
    }

    /// What an admin's Mac does after each sync: rotate when someone who may
    /// hold the newest key has left, give every member a copy of it, and link
    /// it to every older key so nothing becomes unreadable. Does nothing for
    /// other roles.
    @discardableResult
    public func maintain() async throws -> TeamRepair {
        var repair = TeamRepair()
        guard let me, state.role(of: me.id)?.canManage == true else { return repair }
        if state.needsRotation {
            repair.rotated = try await rotate()
        }
        guard let e = state.current, let key = keys[e.id] else { return repair }
        for m in state.members.values where wrapsPresent[e.id]?.contains(m.identity.id) != true {
            try await writeWrap(key, epoch: e.id, for: m.identity)
            repair.wraps.append(m.identity.id)
        }
        repair.links += try await linkMissing()
        return repair
    }

    private func currentKey() throws -> (ULID, SymmetricKey) {
        guard let e = state.current, let key = keys[e.id] else {
            throw VaultError.notPermitted("This Mac has not received the team vault's newest key yet.")
        }
        return (e.id, key)
    }

    /// Signs and writes an event, refusing one the membership rules would ignore.
    @discardableResult
    private func record(_ change: MembershipEvent.Change, id: ULID = ULID()) async throws -> MembershipEvent {
        guard let me else { throw VaultError.locked }
        let e = try MembershipEvent.signed(change, by: me, vaultId: vaultId, id: id)
        var next = state
        if let newest = events.keys.max(), e.id <= newest {
            next = TeamState(header: header, events: Array(events.values) + [e])
        } else {
            next.appendNewest(e)
        }
        if let why = next.rejected[e.id] { throw VaultError.notPermitted("The team vault refused this change: \(why).") }
        try await storage.writeNew(Self.membersDir.appending("\(e.id.string).json"), data: try e.encoded())
        events[e.id] = e
        state = next
        return e
    }

    private func writeWrap(_ key: SymmetricKey, epoch: ULID, for member: PublicIdentity) async throws {
        let path = Self.keysDir.appending(epoch.string).appending("\(member.id.uuidString).json")
        if try await storage.exists(path) { wrapsPresent[epoch, default: []].insert(member.id); return }
        try await storage.writeNew(path, data: try TeamKeys.wrap(key, for: member, vaultId: vaultId, epoch: epoch).encoded())
        wrapsPresent[epoch, default: []].insert(member.id)
    }

    /// Links the current epoch to every older key this Mac holds that the
    /// current one cannot already reach.
    private func linkMissing() async throws -> [ULID] {
        guard let e = state.current, let key = keys[e.id] else { return [] }
        var written: [ULID] = []
        for older in keys.keys.sorted(by: >) where older != e.id && !reachable(from: e.id).contains(older) {
            let path = Self.keysDir.appending(e.id.string).appending("prev-\(older.string).json")
            if try await !storage.exists(path) {
                try await storage.writeNew(path, data: try TeamKeys.link(keys[older]!, older: older, under: key, newer: e.id, vaultId: vaultId).encoded())
                written.append(older)
            }
            linksPresent[e.id, default: []].insert(older)
        }
        return written
    }

    private func reachable(from epoch: ULID) -> Set<ULID> {
        var seen: Set<ULID> = [epoch]
        var queue = [epoch]
        while let next = queue.popLast() {
            for older in linksPresent[next] ?? [] where seen.insert(older).inserted { queue.append(older) }
        }
        return seen
    }
}

/// One line of a team vault's membership log (FR-19).
public struct TeamLogEntry: Equatable, Sendable, Identifiable {
    public enum Change: Equatable, Sendable {
        case asked(UUID)
        case added(UUID, TeamRole)
        case roleChanged(UUID, TeamRole)
        case removed(UUID)
        case left(UUID)
        case rotated
        case named(UUID)
        case titled
        case agentRules(TeamAgentRules)
        case humansOnly(UUID, Bool)
        case invited(TeamRole)
        case ownershipTransferred(UUID)
        case licensed
    }
    public var id: ULID
    public var date: Date { id.timestamp }
    public var author: UUID
    public var change: Change
    /// Why every Mac ignores this change, if it does.
    public var rejected: String?
    /// Arrived after newer changes were applied (see `TeamVaultStore.lateEvents`).
    public var late: Bool
}

/// What a team vault holds about its license (sealed under the team key).
public struct TeamVaultLicense: Codable, Equatable, Sendable {
    /// The signed team-vault entitlement from the owner's Team key.
    public var entitlement: String
    /// People using seats in the owner's other team vaults, as their Mac last counted.
    public var elsewhere: Int
    public init(entitlement: String, elsewhere: Int) { self.entitlement = entitlement; self.elsewhere = elsewhere }
}
