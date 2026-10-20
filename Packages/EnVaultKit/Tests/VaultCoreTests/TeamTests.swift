import Testing
import Foundation
import CryptoKit
@testable import VaultCore

private func person(_ name: String) -> UserIdentity {
    UserIdentity(id: UUID(), name: name, createdAt: Date(),
                 agreementKey: Curve25519.KeyAgreement.PrivateKey(), signingKey: Curve25519.Signing.PrivateKey())
}

/// A team vault's membership as files: the header plus every event and wrap
/// any Mac has written. "Offline" Macs keep their own copy and merge later.
private struct Log {
    let header: TeamHeader
    var events: [MembershipEvent] = []
    var keys: [ULID: SymmetricKey] = [:]          // what admins generated, by epoch
    var wraps: [ULID: [UUID: KeyWrap]] = [:]
    var vaultId: UUID { header.vaultId }
    var state: TeamState { TeamState(header: header, events: events) }

    init(owner: UserIdentity) throws {
        header = try TeamHeader.create(owner: owner)
    }

    mutating func record(_ change: MembershipEvent.Change, by author: UserIdentity) throws {
        events.append(try MembershipEvent.signed(change, by: author, vaultId: vaultId))
    }

    /// `author` starts a new epoch for every active member (or `recipients`).
    @discardableResult
    mutating func rotate(by author: UserIdentity, recipients: [PublicIdentity]? = nil) throws -> ULID {
        let to = recipients ?? state.members.values.map(\.identity)
        let id = ULID()
        let key = TeamKeys.newKey()
        let change = MembershipEvent.Change.rotate(recipients: to.map(\.id), keyCommitment: TeamKeys.commitment(to: key, vaultId: vaultId, epoch: id))
        events.append(try MembershipEvent.signed(change, by: author, vaultId: vaultId, id: id))
        keys[id] = key
        for m in to { wraps[id, default: [:]][m.id] = try TeamKeys.wrap(key, for: m, vaultId: vaultId, epoch: id) }
        return id
    }

    /// Approves `newcomer` and gives them the current epoch's key.
    mutating func add(_ newcomer: UserIdentity, as role: TeamRole, by admin: UserIdentity) throws {
        let pub = try newcomer.publicIdentity().unnamed
        try record(.add(identity: pub, role: role), by: admin)
        if let e = state.current, let key = keys[e.id] {
            wraps[e.id, default: [:]][newcomer.id] = try TeamKeys.wrap(key, for: pub, vaultId: vaultId, epoch: e.id)
        }
    }

    /// What `who` can unwrap for the current epoch, as their Mac would.
    func currentKey(for who: UserIdentity) throws -> SymmetricKey {
        let s = state
        guard let e = s.current else { throw VaultError.locked }
        guard s.members[who.id] != nil, let w = wraps[e.id]?[who.id] else { throw VaultError.locked }
        return try TeamKeys.unwrap(w, identity: who, vaultId: vaultId, epoch: e)
    }

    /// Merges another copy (an offline Mac coming back).
    mutating func merge(_ other: Log) {
        let known = Set(events.map(\.id))
        events += other.events.filter { !known.contains($0.id) }
        keys.merge(other.keys) { a, _ in a }
        for (e, w) in other.wraps { wraps[e, default: [:]].merge(w) { a, _ in a } }
    }
}

@Suite struct TeamTests {
    let ada = person("Ada"), bob = person("Bob"), cyd = person("Cyd"), dee = person("Dee")

    private func team() throws -> Log {
        var log = try Log(owner: ada)
        try log.rotate(by: ada)
        try log.add(bob, as: .admin, by: ada)
        try log.add(cyd, as: .member, by: ada)
        try log.add(dee, as: .viewer, by: bob)
        return log
    }

    @Test func headerIsSignedByItsOwner() throws {
        let h = try TeamHeader.create(owner: ada)
        #expect(try TeamHeader.decode(try h.encoded()) == h)
        var forged = h
        forged.owner = try bob.publicIdentity()
        #expect(!forged.isValid)
        #expect(throws: VaultError.self) { try TeamHeader.decode(try forged.encoded()) }
    }

    @Test func formatOneReadersRefuseATeamVault() throws {
        let data = try TeamHeader.create(owner: ada).encoded()
        #expect(throws: VaultError.unsupportedFormatVersion(2)) { try VaultHeader.decode(data) }
    }

    @Test func everyMemberUnwrapsTheSameKey() throws {
        let log = try team()
        let s = log.state
        #expect(s.rejected.isEmpty)
        #expect(s.role(of: ada.id) == .owner && s.role(of: bob.id) == .admin)
        #expect(s.role(of: cyd.id) == .member && s.role(of: dee.id) == .viewer)
        let k = try log.currentKey(for: ada)
        for p in [bob, cyd, dee] { #expect(try log.currentKey(for: p) == k) }
        #expect(!s.needsRotation)
    }

    @Test func rolesAreEnforced() throws {
        var log = try team()
        let eve = person("Eve")
        try log.record(.add(identity: try eve.publicIdentity().unnamed, role: .member), by: cyd)     // member adds
        try log.record(.setRole(member: cyd.id, role: .admin), by: cyd)                       // self-promotion
        try log.record(.setRole(member: ada.id, role: .viewer), by: bob)                      // admin demotes owner
        try log.record(.remove(member: ada.id), by: bob)                                      // owner removed
        try log.record(.add(identity: try eve.publicIdentity().unnamed, role: .owner), by: ada)       // second owner
        try log.record(.rotate(recipients: [cyd.id], keyCommitment: Data(count: 32)), by: dee) // viewer rotates
        let s = log.state
        #expect(s.rejected.count == 6)
        #expect(s.members[eve.id] == nil)
        #expect(s.role(of: cyd.id) == .member && s.role(of: ada.id) == .owner)
    }

    @Test func forgedEventsAreIgnored() throws {
        var log = try team()
        // Cyd writes an event claiming Ada as its author.
        var forged = try MembershipEvent.signed(.setRole(member: cyd.id, role: .admin), by: cyd, vaultId: log.vaultId)
        forged.author = ada.id
        log.events.append(forged)
        // An event signed for another vault, replayed here.
        log.events.append(try MembershipEvent.signed(.setRole(member: dee.id, role: .admin), by: ada, vaultId: UUID()))
        let s = log.state
        #expect(s.rejected[forged.id] == "bad signature")
        #expect(s.role(of: cyd.id) == .member && s.role(of: dee.id) == .viewer)
    }

    @Test func removalAndRotationLockTheMemberOut() throws {
        var log = try team()
        let before = try log.currentKey(for: cyd)
        try log.record(.remove(member: cyd.id), by: bob)
        #expect(log.state.needsRotation)
        try log.rotate(by: bob)
        let s = log.state
        #expect(!s.needsRotation && s.members[cyd.id] == nil)
        #expect(throws: VaultError.self) { try log.currentKey(for: cyd) }
        #expect(try log.currentKey(for: dee) != before)
        // A wrap Cyd makes for themselves with a key they choose fails the commitment.
        let e = try #require(s.current)
        let guess = try TeamKeys.wrap(TeamKeys.newKey(), for: try cyd.publicIdentity().unnamed, vaultId: log.vaultId, epoch: e.id)
        #expect(throws: VaultError.self) { try TeamKeys.unwrap(guess, identity: cyd, vaultId: log.vaultId, epoch: e) }
    }

    @Test func newcomersCountAsKeyHolders() throws {
        // Cyd and Dee joined after the only rotation, which was signed for Ada alone.
        var log = try team()
        #expect(log.state.current?.recipients == [ada.id])
        #expect(log.state.current?.holders == [ada.id, bob.id, cyd.id, dee.id])
        try log.record(.remove(member: dee.id), by: ada)
        #expect(log.state.needsRotation)
    }

    @Test func membersMayLeave() throws {
        var log = try team()
        try log.record(.remove(member: dee.id), by: dee)
        #expect(log.state.members[dee.id] == nil)
    }

    @Test func concurrentAddsBothApply() throws {
        let base = try team()
        var onAda = base, onBob = base
        let eve = person("Eve"), fay = person("Fay")
        try onAda.add(eve, as: .member, by: ada)
        try onBob.add(fay, as: .viewer, by: bob)
        onAda.merge(onBob); onBob.merge(onAda)
        for log in [onAda, onBob] {
            let s = log.state
            #expect(s.role(of: eve.id) == .member && s.role(of: fay.id) == .viewer)
            #expect(try log.currentKey(for: eve) == log.currentKey(for: fay))
        }
    }

    @Test func concurrentRemovalsForceAnotherRotation() async throws {
        let base = try team()
        var onAda = base, onBob = base
        try onAda.record(.remove(member: cyd.id), by: ada)
        try onAda.rotate(by: ada)                       // still reaches Dee
        try? await Task.sleep(for: .milliseconds(3))
        try onBob.record(.remove(member: dee.id), by: bob)
        try onBob.rotate(by: bob)                       // still reaches Cyd
        onAda.merge(onBob)
        var s = onAda.state
        #expect(s.members[cyd.id] == nil && s.members[dee.id] == nil)
        #expect(s.needsRotation)                        // newest epoch still reaches Cyd
        try onAda.rotate(by: ada)
        s = onAda.state
        #expect(!s.needsRotation && s.current?.recipients == [ada.id, bob.id])
    }

    @Test func aRemovedAdminCannotActAfterwards() async throws {
        let base = try team()
        var onAda = base, onBob = base
        try onAda.record(.remove(member: bob.id), by: ada)
        try? await Task.sleep(for: .milliseconds(3))
        // Bob, offline and unaware, adds someone after the removal.
        try onBob.add(person("Eve"), as: .admin, by: bob)
        onAda.merge(onBob)
        let s = onAda.state
        #expect(s.members.count == 3)
        #expect(s.rejected.values.contains("author is not a member"))
    }

    @Test func revisionsCarryTheirAuthor() throws {
        let log = try team()
        let s = log.state
        let e = try #require(s.current)
        let key = try log.currentKey(for: cyd)
        let item = UUID(), rev = ULID()
        let data = try TeamRevisionFile.encode("A=1", vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: rev, epoch: e.id, key: key, author: cyd)
        let keys = [e.id: try log.currentKey(for: dee)]
        let (value, author) = try TeamRevisionFile.decode(String.self, from: data, vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: rev, state: s, keys: keys)
        #expect(value == "A=1" && author == cyd.id)
        // Bound to its place: another item or revision id fails.
        #expect(throws: VaultError.self) { try TeamRevisionFile.decode(String.self, from: data, vaultId: log.vaultId, scope: .item, ownerId: UUID(), revisionId: rev, state: s, keys: keys) }
        // A viewer's revision is rejected even with the right key.
        let byDee = try TeamRevisionFile.encode("A=2", vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: ULID(), epoch: e.id, key: key, author: dee)
        #expect(throws: VaultError.self) { try TeamRevisionFile.decode(String.self, from: byDee, vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: ULID(), state: s, keys: keys) }
    }

    @Test func revisionsAfterRemovalAreRejected() throws {
        var log = try team()
        let e = try #require(log.state.current)
        let oldKey = try log.currentKey(for: cyd)
        try log.record(.remove(member: cyd.id), by: ada)
        try log.rotate(by: ada)
        // Cyd still holds the old epoch's key and writes with it.
        let item = UUID(), rev = ULID()
        let data = try TeamRevisionFile.encode("STOLEN=1", vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: rev, epoch: e.id, key: oldKey, author: cyd)
        #expect(throws: VaultError.self) {
            try TeamRevisionFile.decode(String.self, from: data, vaultId: log.vaultId, scope: .item, ownerId: item, revisionId: rev, state: log.state, keys: [e.id: oldKey])
        }
    }

    @Test func eventsRoundTripAsFiles() throws {
        let log = try team()
        let decoded = try log.events.map { try MembershipEvent.decode(try $0.encoded()) }
        #expect(decoded == log.events)
        #expect(TeamState(header: log.header, events: decoded.reversed()).rejected.isEmpty)
    }
}
