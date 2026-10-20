import Foundation
import CryptoKit

public enum TeamRole: String, Codable, Sendable, CaseIterable, Comparable {
    case viewer, member, admin, owner

    var rank: Int {
        switch self { case .viewer: 0; case .member: 1; case .admin: 2; case .owner: 3 }
    }
    public static func < (a: TeamRole, b: TeamRole) -> Bool { a.rank < b.rank }

    public var canWrite: Bool { self >= .member }
    public var canManage: Bool { self >= .admin }
}

/// One signed change to a team vault's membership, stored as
/// `members/<id>.json`. Files are immutable; the team's state is the fold of
/// all of them in id (ULID) order, each checked against the roles in force
/// just before it (FR-11, FR-18, FR-21).
public struct MembershipEvent: Codable, Equatable, Sendable {
    public enum Change: Codable, Equatable, Sendable {
        /// Approves a person who asked to join (their self-signed identity,
        /// unnamed) with a role.
        case add(identity: PublicIdentity, role: TeamRole)
        case setRole(member: UUID, role: TeamRole)
        /// Removes a member; members may also remove themselves (leave, FR-15).
        case remove(member: UUID)
        /// Starts a key epoch named by this event's id. The key itself travels in
        /// per-member wraps (`keys/<epoch>/<member>.json`); the commitment lets
        /// every recipient check that the key they unwrapped is the one signed here.
        case rotate(recipients: [UUID], keyCommitment: Data)
        /// A member's display name, sealed under a team key (NFR-13). Written
        /// by the member themselves or by an owner or admin.
        case name(member: UUID, name: SealedName)
        /// The vault's own display name, sealed under a team key; owner or admin.
        case title(SealedName)
    }

    public var id: ULID
    public var author: UUID
    public var change: Change
    public var signature: Data

    /// Signs `change` as `author`. `id` is a new ULID unless given (tests).
    public static func signed(_ change: Change, by author: UserIdentity, vaultId: UUID, id: ULID = ULID()) throws -> MembershipEvent {
        var e = MembershipEvent(id: id, author: author.id, change: change, signature: Data())
        e.signature = try author.signingKey.signature(for: e.signedBytes(vaultId: vaultId))
        return e
    }

    func signedBytes(vaultId: UUID) -> Data {
        var c = CanonicalBytes("envault-member-event:1")
        c.add(vaultId)
        c.add(id)
        c.add(author)
        switch change {
        case .add(let identity, let role):
            c.add("add"); c.add(identity.signedBytes); c.add(identity.signature); c.add(role.rawValue)
        case .setRole(let member, let role):
            c.add("setRole"); c.add(member); c.add(role.rawValue)
        case .remove(let member):
            c.add("remove"); c.add(member)
        case .rotate(let recipients, let commitment):
            c.add("rotate"); c.add(recipients.map(\.uuidString).sorted().joined(separator: ",")); c.add(commitment)
        case .name(let member, let name):
            c.add("name"); c.add(member); c.add(name.epoch); c.add(name.box)
        case .title(let name):
            c.add("title"); c.add(name.epoch); c.add(name.box)
        }
        return c.data
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> MembershipEvent {
        do { return try JSONDecoder().decode(MembershipEvent.self, from: data) } catch {
            throw VaultError.corruptRevision("membership event: \(error)")
        }
    }
}

/// A key epoch: started by a `rotate` event, named by its id.
public struct TeamEpoch: Equatable, Sendable {
    public var id: ULID
    public var author: UUID
    /// Who the rotation was signed for.
    public var recipients: Set<UUID>
    public var keyCommitment: Data
    /// Everyone who may hold the key: the recipients plus members added while
    /// this was the newest epoch (their approval came with a wrap of it).
    public var holders: Set<UUID>
}

/// What a team vault's membership log says, folded in order.
public struct TeamState: Sendable {
    public struct Member: Equatable, Sendable {
        public var identity: PublicIdentity
        public var role: TeamRole
    }

    public let vaultId: UUID
    public private(set) var members: [UUID: Member] = [:]
    /// Everyone who was ever a member, for checking old revisions' authors.
    public private(set) var everyone: [UUID: PublicIdentity] = [:]
    public private(set) var epochs: [TeamEpoch] = []
    /// Each member's latest sealed name.
    public private(set) var names: [UUID: SealedName] = [:]
    /// The vault's latest sealed display name.
    public private(set) var title: SealedName?
    /// Events ignored, with the reason (shown in the membership log, FR-18/FR-19).
    public private(set) var rejected: [ULID: String] = [:]
    /// Per member, their role after each event that changed it (nil = removed), in order.
    private var roleHistory: [UUID: [(at: ULID, role: TeamRole?)]] = [:]

    /// Folds `events` (any order) onto the header's owner.
    public init(header: TeamHeader, events: [MembershipEvent]) {
        vaultId = header.vaultId
        let owner = header.owner
        members[owner.id] = Member(identity: owner, role: .owner)
        everyone[owner.id] = owner
        roleHistory[owner.id] = [(ULID.zero, .owner)]
        var seen = Set<ULID>()
        for e in events.sorted(by: { $0.id < $1.id }) where seen.insert(e.id).inserted {
            if let reason = apply(e) { rejected[e.id] = reason }
        }
    }

    /// Applies an event newer than every event folded so far, such as one
    /// just signed on this Mac, without folding the whole log again.
    mutating func appendNewest(_ e: MembershipEvent) {
        if let reason = apply(e) { rejected[e.id] = reason }
    }

    public var current: TeamEpoch? { epochs.last }

    /// Someone who may hold the newest epoch's key is no longer a member (a
    /// removal not yet followed by a rotation, or two admins removing people
    /// concurrently): an admin must rotate before anyone writes new secrets.
    public var needsRotation: Bool {
        guard let e = current else { return true }
        return !e.holders.isSubset(of: Set(members.keys))
    }

    public func role(of member: UUID) -> TeamRole? { members[member]?.role }

    /// The member's role as of `revision`: what decides whether a revision with
    /// that id was theirs to write (FR-18).
    public func role(of member: UUID, at revision: ULID) -> TeamRole? {
        roleHistory[member]?.last(where: { $0.at <= revision })?.role ?? nil
    }

    public func epoch(_ id: ULID) -> TeamEpoch? { epochs.first { $0.id == id } }

    /// Returns why `e` is ignored, or nil after applying it.
    private mutating func apply(_ e: MembershipEvent) -> String? {
        guard let author = members[e.author] else { return "author is not a member" }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: author.identity.signingKey),
              key.isValidSignature(e.signature, for: e.signedBytes(vaultId: vaultId)) else { return "bad signature" }
        let by = author.role
        switch e.change {
        case .add(let identity, let role):
            guard by.canManage else { return "only an owner or admin adds members" }
            guard role != .owner else { return "nobody is added as owner" }
            guard identity.isValid else { return "the identity is not self-signed" }
            guard identity.name.isEmpty else { return "names are stored encrypted" }
            guard members[identity.id] == nil else { return "already a member" }
            set(identity.id, Member(identity: identity, role: role), at: e.id)
            everyone[identity.id] = identity
            if !epochs.isEmpty { epochs[epochs.count - 1].holders.insert(identity.id) }
        case .setRole(let member, let role):
            guard by.canManage else { return "only an owner or admin changes roles" }
            guard let target = members[member] else { return "not a member" }
            guard target.role != .owner, role != .owner else { return "the owner's role does not change this way" }
            set(member, Member(identity: target.identity, role: role), at: e.id)
        case .remove(let member):
            guard let target = members[member] else { return "not a member" }
            guard target.role != .owner else { return "the owner cannot be removed" }
            guard by.canManage || member == e.author else { return "only an owner or admin removes others" }
            set(member, nil, at: e.id)
        case .rotate(let recipients, let commitment):
            guard by.canManage else { return "only an owner or admin rotates keys" }
            guard commitment.count == 32 else { return "bad key commitment" }
            let set = Set(recipients)
            guard set.isSubset(of: Set(members.keys)) else { return "a recipient is not a member" }
            epochs.append(TeamEpoch(id: e.id, author: e.author, recipients: set, keyCommitment: commitment, holders: set))
        case .name(let member, let name):
            guard members[member] != nil else { return "not a member" }
            guard by.canManage || member == e.author else { return "only an owner or admin names others" }
            guard epoch(name.epoch) != nil else { return "unknown key epoch" }
            names[member] = name
        case .title(let name):
            guard by.canManage else { return "only an owner or admin renames the vault" }
            guard epoch(name.epoch) != nil else { return "unknown key epoch" }
            title = name
        }
        return nil
    }

    private mutating func set(_ id: UUID, _ m: Member?, at event: ULID) {
        members[id] = m
        roleHistory[id, default: []].append((event, m?.role))
    }
}
