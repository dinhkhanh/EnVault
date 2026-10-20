import Testing
import Foundation
import CryptoKit
@testable import VaultCore

private func person(_ name: String) -> UserIdentity {
    UserIdentity(id: UUID(), name: name, createdAt: Date(),
                 agreementKey: Curve25519.KeyAgreement.PrivateKey(), signingKey: Curve25519.Signing.PrivateKey())
}

private let mac = DeviceIdentity(id: UUID(), name: "Test Mac")

/// Everyone's Macs exchange every file, as a finished sync would.
private func sync(_ macs: MemoryStorage...) async {
    var all: [String: Data] = [:]
    for m in macs { all.merge(await m.allFiles()) { a, _ in a } }
    for m in macs { await m.merge(all) }
}

/// One person's view of the vault on their own Mac.
private func open(_ storage: MemoryStorage, as who: UserIdentity, seen: TeamSeen = TeamSeen()) async throws -> TeamVaultStore {
    let store = try await TeamVaultStore.open(storage: storage, device: mac)
    try await store.unlock(identity: who, seen: seen)
    return store
}

private let secret = ItemPayload.envFile(text: "API_KEY=1")

@Suite struct TeamVaultStoreTests {
    let ada = person("Ada"), bob = person("Bob"), cyd = person("Cyd"), dee = person("Dee")

    /// Ada owns the vault; Bob is an admin, Cyd a member, Dee a viewer. One Mac each, synced.
    private func team() async throws -> (TeamVaultStore, [UUID: MemoryStorage]) {
        let macs = [ada, bob, cyd, dee].reduce(into: [UUID: MemoryStorage]()) { $0[$1.id] = MemoryStorage() }
        let store = try await TeamVaultStore.create(storage: macs[ada.id]!, owner: ada, title: "Acme", device: mac)
        try await store.add(try bob.publicIdentity(), name: "Bob", role: .admin)
        try await store.add(try cyd.publicIdentity(), name: "Cyd", role: .member)
        try await store.add(try dee.publicIdentity(), name: "Dee", role: .viewer)
        await sync(macs[ada.id]!, macs[bob.id]!, macs[cyd.id]!, macs[dee.id]!)
        return (store, macs)
    }

    @Test func ownerCreatesAndReopens() async throws {
        let storage = MemoryStorage()
        let created = try await TeamVaultStore.create(storage: storage, owner: ada, title: "Acme", device: mac)
        let p = try await created.createProject(name: "api")
        let item = try await created.createItem(in: p.id, name: ".env", payload: secret)

        let store = try await open(storage, as: ada)
        #expect(await store.access == .member(.owner))
        #expect(await store.title == "Acme")
        #expect(await store.members().map(\.name) == ["Ada"])
        #expect(await store.item(item.id)?.payload == secret)
        #expect(await store.author(of: item.revisionId) == ada.id)
        #expect(await store.rejectedFiles.isEmpty)
        // A format-1 reader refuses it.
        await #expect(throws: VaultError.unsupportedFormatVersion(2)) { try await VaultStore.open(storage: storage) }
    }

    @Test func secretsSeenByFormerMembersAreListedUntilChanged() async throws {
        let (store, _) = try await team()
        let p = try await store.createProject(name: "api")
        let seen = try await store.createItem(in: p.id, name: "seen", payload: secret)
        #expect(await store.exposedItems().isEmpty)
        try await store.remove(dee.id)
        let later = try await store.createItem(in: p.id, name: "later", payload: secret)
        #expect(await store.exposedItems().map(\.item.id) == [seen.id])
        #expect(await store.exposedItems().first?.readers == [dee.id])
        #expect(await store.formerReaders(of: seen.revisionId) == [dee.id])
        #expect(await store.formerReaders(of: later.revisionId).isEmpty)

        try await store.remove(cyd.id)                       // Cyd could read "later" too
        #expect(await store.exposedItems().map(\.item.id).sorted() == [seen.id, later.id].sorted())
        let rotated = try await store.updateItem(seen.id, payload: .envFile(text: "API_KEY=2"))
        #expect(await store.formerReaders(of: rotated.revisionId).isEmpty)
        #expect(await store.exposedItems().map(\.item.id) == [later.id])
    }

    @Test func theMembershipLogTellsTheStory() async throws {
        let (store, macs) = try await team()
        try await store.setRole(of: cyd.id, to: .viewer)
        let onDee = try await open(macs[dee.id]!, as: dee)
        await sync(macs[ada.id]!, macs[dee.id]!)
        try await onDee.leave()
        await sync(macs[ada.id]!, macs[dee.id]!)
        try await store.refresh()
        try await store.remove(bob.id)
        let log = await store.log().map(\.change)
        #expect(Array(log.prefix(4)) == [.rotated, .removed(bob.id), .left(dee.id), .roleChanged(cyd.id, .viewer)])
        #expect(log.contains(.added(cyd.id, .member)) && log.contains(.titled) && log.contains(.named(ada.id)))
        #expect(await store.log().allSatisfy { $0.rejected == nil })
    }

    @Test func teamRulesOnlyTightenAMembersOwnSetting() async throws {
        let (store, macs) = try await team()
        let onCyd = try await open(macs[cyd.id]!, as: cyd)
        await #expect(throws: VaultError.self) { try await onCyd.setAgentRules(TeamAgentRules(values: .allow)) }   // members can't
        try await store.setAgentRules(TeamAgentRules(enabled: true, values: .never, writes: false))
        let rules = await store.state.agentRules
        let mine = AIAgents.Policy(enabled: true, values: .allow, writes: true)
        #expect(mine.restricted(by: rules) == AIAgents.Policy(enabled: true, values: .never, writes: false))
        let strict = AIAgents.Policy(enabled: false, values: .ask, writes: false)
        #expect(strict.restricted(by: TeamAgentRules(values: .allow)) == strict)     // can't loosen
        #expect(mine.restricted(by: nil) == mine)
        #expect(await store.log().first?.change == .agentRules(TeamAgentRules(enabled: true, values: .never, writes: false)))
    }

    @Test func humansOnlyIsInvisibleToAgents() async throws {
        let (store, macs) = try await team()
        let p = try await store.createProject(name: "billing")
        let prod = try await store.createItem(in: p.id, name: "prod.env", payload: secret)
        let dev = try await store.createItem(in: p.id, name: "dev.env", payload: secret)
        try await store.setHumansOnly(prod.id, true)

        let asAgent = try await open(macs[ada.id]!, as: ada)
        await sync(macs[ada.id]!)
        try await asAgent.refresh()
        await asAgent.hideHumansOnly()
        #expect(await asAgent.items(in: p.id).map(\.id) == [dev.id])
        #expect(await asAgent.item(prod.id) == nil)
        #expect(await asAgent.history(of: prod.id).isEmpty)
        await #expect(throws: VaultError.self) { try await asAgent.updateItem(prod.id, payload: .envFile(text: "X=1")) }
        await #expect(throws: VaultError.self) { try await asAgent.createItem(in: p.id, name: "prod.env", payload: secret) }

        try await store.setHumansOnly(p.id, true)
        try await asAgent.refresh()
        #expect(await asAgent.projects().isEmpty)
        #expect(await asAgent.allItems().isEmpty)
        await #expect(throws: VaultError.self) { try await asAgent.createProject(name: "billing") }
        #expect(await store.items(in: p.id).count == 2)           // people still see everything
    }

    @Test func ownershipMovesToAnAdmin() async throws {
        let (store, macs) = try await team()
        await #expect(throws: VaultError.self) { try await store.transferOwnership(to: cyd.id) }   // a member
        let onBob = try await open(macs[bob.id]!, as: bob)
        await #expect(throws: VaultError.self) { try await onBob.transferOwnership(to: bob.id) }  // not the owner
        try await store.transferOwnership(to: bob.id)
        let s = await store.state
        #expect(s.owner == bob.id && s.role(of: ada.id) == .admin)
        #expect(store.header.owner.id == ada.id)                      // the pinned root stays
        // The new owner can do what owners do; the old one can now be removed.
        await sync(macs[ada.id]!, macs[bob.id]!)
        try await onBob.refresh()
        try await onBob.remove(ada.id)
        #expect(await onBob.state.members[ada.id] == nil)
        #expect(await onBob.log().contains { $0.change == .ownershipTransferred(bob.id) })
    }

    @Test func aTeamVaultExportsAsAPersonalVault() async throws {
        let (store, macs) = try await team()
        let p = try await store.createProject(name: "api")
        let item = try await store.createItem(in: p.id, name: ".env", payload: secret)
        try await store.updateItem(item.id, payload: .envFile(text: "API_KEY=2"))
        let target = MemoryStorage()
        let kdf = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))
        await #expect(throws: VaultError.self) {
            try await open(macs[cyd.id]!, as: cyd).exportAsPersonalVault(to: MemoryStorage(), passphrase: "pw-123456", kdf: kdf)
        }
        try await store.exportAsPersonalVault(to: target, passphrase: "pw-123456", kdf: kdf)
        let personal = try await VaultStore.open(storage: target)
        try await personal.unlock(passphrase: "pw-123456")
        let copied = try #require(await personal.allItems().first)
        #expect(await personal.projects().map(\.name) == ["api"])
        #expect(await personal.history(of: copied.id).map(\.payload) == [.envFile(text: "API_KEY=2"), secret])
    }

    @Test func onlyTheOwnerSetsTheLicense() async throws {
        let (store, macs) = try await team()
        await #expect(throws: VaultError.self) { try await open(macs[bob.id]!, as: bob).setLicense(TeamVaultLicense(entitlement: "EVL1.x.y", elsewhere: 0)) }
        try await store.setLicense(TeamVaultLicense(entitlement: "EVL1.a.b", elsewhere: 0))
        try await store.setLicense(TeamVaultLicense(entitlement: "EVL1.c.d", elsewhere: 3))   // a renewal, and people in other vaults
        #expect(await store.license == TeamVaultLicense(entitlement: "EVL1.c.d", elsewhere: 3))
        #expect(try await open(macs[dee.id]!, as: dee).license == nil)   // not synced yet
        await sync(macs[ada.id]!, macs[dee.id]!)
        #expect(try await open(macs[dee.id]!, as: dee).license?.entitlement == "EVL1.c.d")
        #expect(await store.log().first?.change == .licensed)
        // Sealed: the key (which names the buyer) is not in any file.
        for (_, data) in await macs[ada.id]!.allFiles() { #expect(!String(decoding: data, as: UTF8.self).contains("EVL1.c.d")) }
    }

    @Test func everyRoleSeesTheSameVault() async throws {
        let (_, macs) = try await team()
        let onCyd = try await open(macs[cyd.id]!, as: cyd)
        #expect(await onCyd.access == .member(.member))
        let p = try await onCyd.createProject(name: "api")
        let item = try await onCyd.createItem(in: p.id, name: ".env", payload: secret)
        await sync(macs[ada.id]!, macs[bob.id]!, macs[cyd.id]!, macs[dee.id]!)

        for who in [ada, bob, dee] {
            let store = try await open(macs[who.id]!, as: who)
            #expect(await store.item(item.id)?.payload == secret)
            #expect(await store.author(of: item.revisionId) == cyd.id)
            #expect(await store.members().map(\.name) == ["Ada", "Bob", "Cyd", "Dee"])
        }
        let onDee = try await open(macs[dee.id]!, as: dee)
        #expect(await onDee.access == .member(.viewer))
        await #expect(throws: VaultError.self) { try await onDee.updateItem(item.id, payload: .envFile(text: "API_KEY=2")) }
        await #expect(throws: VaultError.self) { try await onCyd.add(try person("Eve").publicIdentity(), name: "Eve", role: .member) }
        #expect(try await onCyd.maintain().isEmpty)
    }

    @Test func namesAndSecretsNeverAppearInFiles() async throws {
        // Words with a space or punctuation cannot occur inside base64 by chance.
        let storage = MemoryStorage()
        let store = try await TeamVaultStore.create(storage: storage, owner: person("Ada Lovelace"), title: "Acme Corp", device: mac)
        try await store.add(try bob.publicIdentity(), name: "Bob Builder", role: .admin)
        let p = try await store.createProject(name: "billing-service")
        try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "STRIPE_KEY=sk_live_42"))
        for (path, data) in await storage.allFiles() {
            let text = String(decoding: data, as: UTF8.self)
            for word in ["Ada Lovelace", "Bob Builder", "Acme Corp", "billing-service", "sk_live_42"] {
                #expect(!text.contains(word), "\(word) in \(path)")
            }
        }
        #expect(await store.members().map(\.name) == ["Ada Lovelace", "Bob Builder"])
    }

    @Test func removalLocksTheMemberOutOfNewSecrets() async throws {
        let (store, macs) = try await team()
        let p = try await store.createProject(name: "api")
        let old = try await store.createItem(in: p.id, name: "old", payload: secret)
        await sync(macs[ada.id]!, macs[cyd.id]!)
        let onCyd = try await open(macs[cyd.id]!, as: cyd)
        #expect(await onCyd.item(old.id) != nil)

        try await store.remove(cyd.id)
        let new = try await store.createItem(in: p.id, name: "new", payload: .envFile(text: "API_KEY=rotated"))
        await sync(macs[ada.id]!, macs[cyd.id]!)
        try await onCyd.refresh()
        #expect(await onCyd.access == .removed)
        #expect(await onCyd.item(new.id) == nil)
        await #expect(throws: VaultError.self) { try await onCyd.createItem(in: p.id, name: "x", payload: secret) }
    }

    @Test func newcomersReadSecretsFromOlderKeys() async throws {
        let (store, macs) = try await team()
        let p = try await store.createProject(name: "api")
        let first = try await store.createItem(in: p.id, name: "first", payload: secret)
        try await store.remove(dee.id)                   // epoch 2
        try await store.remove(cyd.id)                   // epoch 3
        let eve = person("Eve")
        try await store.add(try eve.publicIdentity(), name: "Eve", role: .member)
        let storage = MemoryStorage()
        await sync(macs[ada.id]!, storage)
        let onEve = try await open(storage, as: eve)
        #expect(await onEve.access == .member(.member))
        #expect(await onEve.item(first.id)?.payload == secret)
        #expect(await onEve.name(of: dee.id) == "Dee")   // former members keep their names in history
        #expect(await onEve.rejectedFiles.isEmpty)
    }

    @Test func concurrentRemovalsAreRepaired() async throws {
        let (_, macs) = try await team()
        let onAda = try await open(macs[ada.id]!, as: ada)
        let onBob = try await open(macs[bob.id]!, as: bob)
        try await onAda.remove(cyd.id)                   // still reaches Dee
        try await Task.sleep(for: .milliseconds(3))
        try await onBob.remove(dee.id)                   // still reaches Cyd
        await sync(macs[ada.id]!, macs[bob.id]!)
        try await onAda.refresh()
        #expect(await onAda.state.needsRotation)
        await #expect(throws: VaultError.self) { try await onAda.createProject(name: "blocked") }

        let repair = try await onAda.maintain()
        #expect(repair.rotated != nil)
        await sync(macs[ada.id]!, macs[bob.id]!, macs[cyd.id]!, macs[dee.id]!)
        try await onBob.refresh()
        #expect(await onBob.access == .member(.admin))
        try await onBob.createProject(name: "unblocked")
        for who in [cyd, dee] {
            #expect(try await open(macs[who.id]!, as: who).access == .removed)
        }
    }

    @Test func aNewcomerMissingTheNewestKeyIsRepaired() async throws {
        let (_, macs) = try await team()
        let onAda = try await open(macs[ada.id]!, as: ada)
        let onBob = try await open(macs[bob.id]!, as: bob)
        // Bob rotates while offline; Ada, unaware, approves Eve with the old key.
        try await onBob.rotate()
        let eve = person("Eve"), eveMac = MemoryStorage()
        try await onAda.add(try eve.publicIdentity(), name: "Eve", role: .member)
        await sync(macs[ada.id]!, macs[bob.id]!, eveMac)
        #expect(try await open(eveMac, as: eve).access == .awaitingKey(.member))

        try await onAda.refresh()
        let repair = try await onAda.maintain()
        #expect(repair.wraps == [eve.id])
        await sync(macs[ada.id]!, eveMac)
        let onEve = try await open(eveMac, as: eve)
        #expect(await onEve.access == .member(.member))
        #expect(await onEve.name(of: eve.id) == "Eve")
        #expect(try await onAda.maintain().isEmpty)
    }

    @Test func aNewcomerApprovedDuringARemovalIsRepaired() async throws {
        let (_, macs) = try await team()
        let onAda = try await open(macs[ada.id]!, as: ada)
        let onBob = try await open(macs[bob.id]!, as: bob)
        // Bob approves Xia; before his files reach Ada, Ada removes Dee, which rotates.
        let xia = person("Xia"), xiaMac = MemoryStorage()
        try await onBob.add(try xia.publicIdentity(), name: "Xia", role: .member)
        try await Task.sleep(for: .milliseconds(3))
        try await onAda.remove(dee.id)
        await sync(macs[ada.id]!, macs[bob.id]!, xiaMac)
        #expect(try await open(xiaMac, as: xia).access == .awaitingKey(.member))

        try await onAda.refresh()
        #expect(try await onAda.maintain().wraps == [xia.id])
        await sync(macs[ada.id]!, xiaMac, macs[dee.id]!)
        #expect(try await open(xiaMac, as: xia).access == .member(.member))
        #expect(try await open(macs[dee.id]!, as: dee).access == .removed)
    }

    @Test func lateChangesAreFlagged() async throws {
        let (_, macs) = try await team()
        let onAda = try await open(macs[ada.id]!, as: ada)
        let onBob = try await open(macs[bob.id]!, as: bob)
        try await onBob.add(try person("Eve").publicIdentity(), name: "Eve", role: .member)   // Bob, offline
        try await Task.sleep(for: .milliseconds(3))
        try await onAda.add(try person("Fay").publicIdentity(), name: "Fay", role: .member)
        await sync(macs[ada.id]!, macs[bob.id]!)
        try await onAda.refresh()
        let late = await onAda.lateEvents
        #expect(late.count == 2)                         // Bob's add and Eve's name

        // A later launch that remembers what it saw flags nothing new.
        // A later launch remembers the flags until an admin dismisses them, and flags nothing new.
        await onAda.dismissLate(late)
        let again = try await open(macs[ada.id]!, as: ada, seen: await onAda.seenState)
        #expect(await again.lateEvents.isEmpty)
    }

    @Test func aRemovedAdminsBackdatedChangeIsFlagged() async throws {
        let (store, macs) = try await team()
        let removedAt = Date()
        try await Task.sleep(for: .milliseconds(3))
        try await store.remove(bob.id)
        await sync(macs[ada.id]!, macs[bob.id]!)
        // Bob signs an add dated just before his removal and uploads it.
        let mallory = person("Mallory")
        let forged = try MembershipEvent.signed(.add(identity: try mallory.publicIdentity().unnamed, role: .admin),
                                                by: bob, vaultId: store.vaultId, id: ULID(date: removedAt))
        try await macs[bob.id]!.writeNew(VaultPath("members", "\(forged.id.string).json"), data: try forged.encoded())
        await sync(macs[ada.id]!, macs[bob.id]!)
        try await store.refresh()
        // The decided limit: the signature and role check pass, so the change
        // applies. CloudKit share removal stops the upload in practice; the
        // flag puts it in front of an admin.
        #expect(await store.state.role(of: mallory.id) == .admin)
        #expect(await store.lateEvents.contains(forged.id))
    }

    @Test func aRevisionArrivingBeforeItsAuthorsApprovalIsKept() async throws {
        let (_, macs) = try await team()
        let onBob = try await open(macs[bob.id]!, as: bob)
        let eve = person("Eve"), eveMac = MemoryStorage()
        try await onBob.add(try eve.publicIdentity(), name: "Eve", role: .member)
        await sync(macs[bob.id]!, eveMac)
        let onEve = try await open(eveMac, as: eve)
        let p = try await onEve.createProject(name: "api")
        let item = try await onEve.createItem(in: p.id, name: ".env", payload: secret)

        // Ada's Mac receives Eve's revisions before Bob's approval of her.
        await macs[ada.id]!.merge(await eveMac.allFiles().filter { $0.key.hasPrefix("projects/") })
        let onAda = try await open(macs[ada.id]!, as: ada)
        #expect(await onAda.item(item.id) == nil)
        await sync(macs[ada.id]!, macs[bob.id]!, eveMac)
        try await onAda.refresh()
        #expect(await onAda.item(item.id)?.payload == secret)
        #expect(await onAda.author(of: item.revisionId) == eve.id)
    }

    @Test func badFilesAreSkippedNotFatal() async throws {
        let (store, macs) = try await team()
        let p = try await store.createProject(name: "api")
        let good = try await store.createItem(in: p.id, name: "good", payload: secret)
        let junk = RevisionLayout.itemPath(projectId: p.id, itemId: UUID(), revisionId: ULID())
        try await macs[ada.id]!.writeNew(junk, data: Data("EVT1{}".utf8))
        try await macs[ada.id]!.writeNew(VaultPath("members", "\(ULID().string).json"), data: Data("{}".utf8))
        let reopened = try await open(macs[ada.id]!, as: ada)
        #expect(await reopened.item(good.id) != nil)
        #expect(await reopened.rejectedFiles.count == 2)
    }

    @Test func aSwappedHeaderIsRefused() async throws {
        let (store, macs) = try await team()
        let pinned = store.header.owner.signingKey
        let mallory = person("Mallory")
        let fake = try TeamHeader.create(owner: mallory, vaultId: store.vaultId)
        try await macs[cyd.id]!.writeReplace(VaultPath(VaultHeader.fileName), data: try fake.encoded())
        await #expect(throws: VaultError.self) { try await TeamVaultStore.open(storage: macs[cyd.id]!, owner: pinned) }
        _ = try await TeamVaultStore.open(storage: macs[ada.id]!, owner: pinned)
    }

    /// NFR-8: 100 members, 50 projects and 2,000 revisions unlock in under 2 s.
    @Test func unlockingAHundredMemberVaultIsFast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("team-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalFolderStorage(root: root)
        let store = try await TeamVaultStore.create(storage: storage, owner: ada, title: "Big", device: mac)
        var people: [UserIdentity] = []
        for i in 0..<99 {
            let p = person("Member \(i)")
            people.append(p)
            try await store.add(try p.publicIdentity(), name: p.name, role: .member)
        }
        for i in 0..<50 {
            let p = try await store.createProject(name: "project \(i)")
            for j in 0..<39 { try await store.createItem(in: p.id, name: "item \(j)", payload: secret) }
        }
        let opened = try await TeamVaultStore.open(storage: storage, device: mac)
        let clock = ContinuousClock()
        let took = try await clock.measure { try await opened.unlock(identity: people[42]) }
        #expect(await opened.allItems().count == 50 * 39)
        #expect(await opened.members().count == 100)
        #expect(took < .seconds(2), "unlock took \(took)")
    }
}

@Suite struct TeamJoiningTests {
    let ada = person("Ada"), bob = person("Bob"), cyd = person("Cyd")

    /// Ada owns the vault, Bob is an admin, Cyd a member; `eve` has a copy of the files and asks to join.
    private func vault() async throws -> (TeamVaultStore, MemoryStorage) {
        let storage = MemoryStorage()
        let store = try await TeamVaultStore.create(storage: storage, owner: ada, title: "Acme", device: mac)
        try await store.add(try bob.publicIdentity(), name: "Bob", role: .admin)
        try await store.add(try cyd.publicIdentity(), name: "Cyd", role: .member)
        return (store, storage)
    }

    @Test func aRequestReachesTheAdminsWithItsName() async throws {
        let (store, storage) = try await vault()
        let eve = person("Eve Example"), eveMac = MemoryStorage()
        await sync(storage, eveMac)
        let onEve = try await open(eveMac, as: eve)
        #expect(await onEve.access == .notMember)
        try await onEve.requestToJoin()
        #expect(await onEve.hasRequestedToJoin)
        await sync(storage, eveMac)

        try await store.refresh()
        let pending = try #require(await store.pendingMembers().first)
        #expect(pending.identity.id == eve.id && pending.name == "Eve Example")
        #expect(pending.safetyCode == eve.safetyCode)
        #expect(try await open(storage, as: bob).pendingMembers().first?.name == "Eve Example")
        #expect(try await open(storage, as: cyd).pendingMembers().first?.name == nil)    // not sealed to members
        for (path, data) in await storage.allFiles() {
            #expect(!String(decoding: data, as: UTF8.self).contains("Eve Example"), "name in \(path)")
        }

        try await store.add(pending.identity, name: pending.name!, role: .member)
        #expect(await store.pendingMembers().isEmpty)
        await sync(storage, eveMac)
        try await onEve.refresh()
        #expect(await onEve.access == .member(.member))
        #expect(await onEve.hasRequestedToJoin == false)
    }

    @Test func aRequestBeforeARemovalNoLongerCounts() async throws {
        let (store, storage) = try await vault()
        let eve = person("Eve"), eveMac = MemoryStorage()
        await sync(storage, eveMac)
        let onEve = try await open(eveMac, as: eve)
        try await onEve.requestToJoin()
        await sync(storage, eveMac)
        try await store.refresh()
        try await store.add(try #require(await store.pendingMembers().first).identity, name: "Eve", role: .member)
        try await store.remove(eve.id)
        #expect(await store.pendingMembers().isEmpty)

        await sync(storage, eveMac)
        try await onEve.refresh()
        #expect(await onEve.access == .removed)
        try await onEve.requestToJoin()
        await sync(storage, eveMac)
        try await store.refresh()
        #expect(await store.pendingMembers().map(\.id) == [eve.id])
    }

    @Test func nobodyAsksOnSomeoneElsesBehalf() async throws {
        let (store, storage) = try await vault()
        let eve = person("Eve")
        // Cyd signs a request carrying Eve's identity.
        var forged = try JoinRequest.signed(by: cyd, managers: [], vaultId: store.vaultId)
        forged.identity = try eve.publicIdentity().unnamed
        try await storage.writeNew(VaultPath("identities", eve.id.uuidString, "\(forged.id.string).json"), data: try forged.encoded())
        // A real request for another vault, replayed here.
        let elsewhere = try JoinRequest.signed(by: eve, managers: [], vaultId: UUID())
        try await storage.writeNew(VaultPath("identities", eve.id.uuidString, "\(elsewhere.id.string).json"), data: try elsewhere.encoded())
        try await store.refresh()
        #expect(await store.pendingMembers().isEmpty)
        #expect(await store.rejectedFiles.keys.filter { $0.hasPrefix("identities/") }.count == 2)
    }

    @Test func theShareUpkeepFindsOnlyAPersonsOwnRequest() async throws {
        let (store, storage) = try await vault()
        let eve = person("Eve"), eveMac = MemoryStorage()
        await sync(storage, eveMac)
        try await open(eveMac, as: eve).requestToJoin()
        await sync(storage, eveMac)
        try await store.refresh()
        let real = try #require(await store.joinRequest(of: eve.id))
        try await store.add(try #require(await store.pendingMembers().first).identity, name: "Eve", role: .member)

        // Mal signs newer requests under Eve's id and the owner's, with keys of his own.
        for id in [eve.id, ada.id] {
            let mal = UserIdentity(id: id, name: "Mal", createdAt: Date(), agreementKey: .init(), signingKey: .init())
            let r = try JoinRequest.signed(by: mal, managers: [], vaultId: store.vaultId)
            try await storage.writeNew(VaultPath("identities", id.uuidString, "\(r.id.string).json"), data: try r.encoded())
        }
        // One of Eve's in a folder spelled in lower case, one dated a year ahead.
        let lower = try JoinRequest.signed(by: eve, managers: [], vaultId: store.vaultId)
        try await storage.writeNew(VaultPath("identities", eve.id.uuidString.lowercased(), "\(lower.id.string).json"), data: try lower.encoded())
        let ahead = try JoinRequest.signed(by: eve, managers: [], vaultId: store.vaultId, id: ULID(date: Date().addingTimeInterval(365 * 86_400)))
        try await storage.writeNew(VaultPath("identities", eve.id.uuidString, "\(ahead.id.string).json"), data: try ahead.encoded())
        try await store.refresh()
        #expect(await store.joinRequest(of: eve.id)?.id == real.id)
        #expect(await store.joinRequest(of: ada.id) == nil)
    }

    @Test func anInvitationFileChecksTheFolder() async throws {
        let (store, storage) = try await vault()
        let invite = try await store.createInvite(role: .viewer)
        let file = try TeamInvite.decode(try invite.encoded())
        #expect(file == invite && file.title == "Acme")

        // Eve's Mac sees the shared folder and checks it against the file.
        let eve = person("Eve"), eveMac = MemoryStorage()
        await sync(storage, eveMac)
        let onEve = try await open(eveMac, as: eve)
        try file.check(header: onEve.header, state: await onEve.state)
        try await onEve.requestToJoin(invite: file.invite)
        await sync(storage, eveMac)
        try await store.refresh()
        let pending = try #require(await store.pendingMembers().first)
        #expect(pending.invitedAs == .viewer && !pending.inviteLapsed)
        #expect(await store.log().contains { $0.change == .invited(.viewer) })

        // A folder whose header someone swapped, a lapsed invitation, an unknown one.
        let fake = try TeamHeader.create(owner: person("Mallory"), vaultId: store.vaultId)
        #expect(throws: VaultError.self) { try file.check(header: fake, state: TeamState(header: fake, events: [])) }
        let state = await store.state
        #expect(throws: VaultError.self) { try file.check(header: store.header, state: state, now: Date().addingTimeInterval(8 * 86_400)) }
        var unknown = file; unknown.invite = ULID()
        #expect(throws: VaultError.self) { try unknown.check(header: store.header, state: state) }
        // Members can't invite.
        await #expect(throws: VaultError.self) { try await open(storage, as: cyd).createInvite(role: .member) }
    }

    @Test func aRequestNamingAnUnknownInvitationIsMarked() async throws {
        let (store, storage) = try await vault()
        let eve = person("Eve"), eveMac = MemoryStorage()
        await sync(storage, eveMac)
        try await open(eveMac, as: eve).requestToJoin(invite: ULID())
        await sync(storage, eveMac)
        try await store.refresh()
        #expect(await store.pendingMembers().first?.inviteLapsed == true)
    }

    @Test func onlyLeavingYourselfCountsAsALeave() async throws {
        let (store, storage) = try await vault()
        let onCyd = try await open(storage, as: cyd)
        #expect(await onCyd.leaveEvent == nil)
        try await onCyd.leave()
        #expect(await onCyd.leaveEvent != nil)
        #expect(await onCyd.access == .removed)
        // Removed by an admin: not this person's own leave.
        try await store.refresh()
        try await store.remove(bob.id)
        #expect(try await open(storage, as: bob).leaveEvent == nil)
    }

    @Test func aProjectMovesInWithItsHistory() async throws {
        let personal = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac,
                                                   kdf: KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32)))
        let p = try await personal.createProject(name: "api")
        let item = try await personal.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1"))
        try await personal.updateItem(item.id, payload: .envFile(text: "A=2"))
        try await personal.createItem(in: p.id, name: "gone", payload: .envFile(text: "B=1"))
        try await personal.deleteItem(try #require(await personal.items(in: p.id).first { $0.name == "gone" }).id)

        let (store, _) = try await vault()
        let exported = try await personal.export(p.id)
        let id = try await store.importProject(exported.history, items: exported.items)
        let copied = try #require(await store.items(in: id).first)
        #expect(await store.items(in: id).count == 1)
        #expect(copied.payload == .envFile(text: "A=2") && copied.createdAt == item.createdAt)
        #expect(await store.history(of: copied.id).map(\.payload) == [.envFile(text: "A=2"), .envFile(text: "A=1")])
        #expect(await store.author(of: copied.revisionId) == ada.id)
    }
}

/// Attacks from the Gate C review: storage is writable by every member, former
/// members and the cloud provider.
@Suite struct TeamTamperingTests {
    let ada = person("Ada"), bob = person("Bob"), cyd = person("Cyd")

    private func vault() async throws -> (TeamVaultStore, MemoryStorage) {
        let storage = MemoryStorage()
        let store = try await TeamVaultStore.create(storage: storage, owner: ada, title: "Acme", device: mac)
        try await store.add(try bob.publicIdentity(), name: "Bob", role: .admin)
        try await store.add(try cyd.publicIdentity(), name: "Cyd", role: .member)
        return (store, storage)
    }

    private func eventPath(_ storage: MemoryStorage, _ match: (MembershipEvent) -> Bool) async throws -> String {
        for (path, data) in await storage.allFiles() where path.hasPrefix("members/") {
            if let e = try? MembershipEvent.decode(data), match(e) { return path }
        }
        throw VaultError.io("no such event")
    }

    @Test func deletingARemovalIsNoticedAndNeverGivesTheKeyBack() async throws {
        let (store, storage) = try await vault()
        try await store.remove(cyd.id)
        let seen = await store.seenState
        let removal = try await eventPath(storage) { if case .remove(cyd.id) = $0.change { true } else { false } }
        try await storage.delete(VaultPath(removal.split(separator: "/").map(String.init)))

        // A Mac that saw the removal notices and stops.
        let onAda = try await open(storage, as: ada, seen: seen)
        #expect(await onAda.isTampered)
        #expect(try await onAda.maintain().isEmpty)
        await #expect(throws: VaultError.self) { try await onAda.createProject(name: "x") }
        await #expect(throws: VaultError.self) { try await onAda.add(try person("Eve").publicIdentity(), name: "Eve", role: .member) }

        // A Mac that never saw it thinks Cyd is a member, but the rotation left Cyd
        // out on purpose, so its upkeep writes no key copy for Cyd.
        let onBob = try await open(storage, as: bob)
        #expect(await onBob.state.role(of: cyd.id) == .member)
        #expect(try await onBob.maintain().wraps.isEmpty)
        #expect(try await open(storage, as: cyd).access == .awaitingKey(.member))
    }

    @Test func aNewcomerCantTakeAFormerMembersId() async throws {
        let (store, _) = try await vault()
        try await store.remove(cyd.id)
        // Mal makes an identity under Cyd's (public) id with keys of their own.
        let mal = UserIdentity(id: cyd.id, name: "Mal", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        await #expect(throws: VaultError.self) { try await store.add(try mal.publicIdentity(), name: "Mal", role: .viewer) }
        // Cyd themselves can come back.
        try await store.add(try cyd.publicIdentity(), name: "Cyd", role: .member)
    }

    @Test func aDifferentlySpelledCopyOfAnEventIsIgnored() async throws {
        let (store, storage) = try await vault()
        try await store.setRole(of: bob.id, to: .member)
        let real = try await eventPath(storage) { if case .setRole(bob.id, .member) = $0.change { true } else { false } }
        let name = String(real.dropFirst("members/".count))
        // The same event under a lowercase name, its signature spoiled: read last, it would replace the real one.
        var copy = try MembershipEvent.decode(try await storage.read(VaultPath("members", name)))
        copy.signature = Data(repeating: 0, count: 64)
        try await storage.writeNew(VaultPath("members", name.lowercased()), data: try copy.encoded())
        let onAda = try await open(storage, as: ada)
        #expect(await onAda.state.role(of: bob.id) == .member)
        #expect(await onAda.rejectedFiles["members/\(name.lowercased())"] != nil)
    }

    @Test func aRemovedMembersBackdatedRevisionIsRefused() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        let item = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "DB=real"))
        let epoch = try #require(await store.state.current)
        let oldKey = try await open(storage, as: cyd)   // Cyd still has a copy of the files and the old key
        _ = oldKey
        let cydsKey = try #require(try await keyFor(cyd, storage: storage, epoch: epoch))
        let whileAMember = ULID()     // later than the real value, before the removal
        try await store.remove(cyd.id)
        let seen = await store.seenState

        // Cyd writes a revision dated before the removal, under the old key.
        var forged = try #require(await store.history(of: item.id).first)
        forged.id = whileAMember
        forged.payload = .envFile(text: "DB=attacker")
        let data = try TeamRevisionFile.encode(forged, vaultId: store.vaultId, scope: .item, ownerId: item.id, revisionId: forged.id, epoch: epoch.id, key: cydsKey, author: cyd)
        try await storage.writeNew(RevisionLayout.itemPath(projectId: p.id, itemId: item.id, revisionId: forged.id), data: data)

        let onAda = try await open(storage, as: ada, seen: seen)
        #expect(await onAda.item(item.id)?.payload == .envFile(text: "DB=real"))
        #expect(await onAda.rejectedFiles.values.contains { $0.contains("lost write access") })
    }

    /// Cyd, removed, writes `payload` as revision `id` of `item` under the epoch key she kept.
    private func forge(_ store: TeamVaultStore, _ storage: MemoryStorage, epoch: TeamEpoch, key: SymmetricKey,
                       from rev: ItemRevision, id: ULID, itemId: UUID, payload: ItemPayload, replace: Bool = false) async throws {
        var forged = rev
        forged.id = id; forged.itemId = itemId; forged.payload = payload
        let data = try TeamRevisionFile.encode(forged, vaultId: store.vaultId, scope: .item, ownerId: itemId, revisionId: id, epoch: epoch.id, key: key, author: cyd)
        let path = RevisionLayout.itemPath(projectId: rev.projectId, itemId: itemId, revisionId: id)
        if replace { try await storage.writeReplace(path, data: data) } else { try await storage.writeNew(path, data: data) }
    }

    @Test func aRemovedMemberCantReuseAKnownRevisionId() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        let item = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "DB=real"))
        let epoch = try #require(await store.state.current)
        let cydsKey = try #require(try await keyFor(cyd, storage: storage, epoch: epoch))
        try await store.remove(cyd.id)
        let seen = await store.seenState
        let real = try #require(await store.history(of: item.id).first)

        // A new item carrying the known id, and the known file itself overwritten in place.
        let twin = UUID()
        try await forge(store, storage, epoch: epoch, key: cydsKey, from: real, id: real.id, itemId: twin, payload: .envFile(text: "DB=attacker"))
        try await forge(store, storage, epoch: epoch, key: cydsKey, from: real, id: real.id, itemId: item.id, payload: .envFile(text: "DB=attacker"), replace: true)

        let onAda = try await open(storage, as: ada, seen: seen)
        #expect(await onAda.item(twin) == nil)
        #expect(await onAda.item(item.id)?.payload != .envFile(text: "DB=attacker"))
        #expect(await onAda.rejectedFiles.values.filter { $0.contains("lost write access") }.count == 2)
    }

    @Test func aRemovedMembersFileIsJudgedBeforeTheKeyArrives() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        let item = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "DB=real"))
        let epoch = try #require(await store.state.current)
        let cydsKey = try #require(try await keyFor(cyd, storage: storage, epoch: epoch))
        // Eve asks to join and waits; her Mac has no key yet.
        let eve = person("Eve")
        let onEve = try await open(storage, as: eve)
        try await onEve.requestToJoin()
        try await store.remove(cyd.id)
        try await onEve.refresh()
        // Cyd's backdated file turns up while Eve still can't open anything.
        let real = try #require(await store.history(of: item.id).first)
        try await forge(store, storage, epoch: epoch, key: cydsKey, from: real, id: ULID(), itemId: item.id, payload: .envFile(text: "DB=attacker"))
        try await onEve.refresh()
        let seen = await onEve.seenState
        try await store.add(try eve.publicIdentity(), name: "Eve", role: .member)
        _ = try await store.maintain()
        let approved = try await open(storage, as: eve, seen: seen)
        #expect(await approved.item(item.id)?.payload == .envFile(text: "DB=real"))
    }

    @Test func whatANewcomerFoundWhileWaitingStaysReadable() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        // Cyd writes, then leaves the team.
        let onCyd = try await open(storage, as: cyd)
        let item = try await onCyd.createItem(in: p.id, name: ".env", payload: .envFile(text: "DB=cyd"))
        try await store.refresh()
        try await store.remove(cyd.id)
        // Eve waits for approval across a relaunch, then gets in.
        let eve = person("Eve")
        let onEve = try await open(storage, as: eve)
        try await onEve.requestToJoin()
        let waiting = try await open(storage, as: eve, seen: await onEve.seenState)
        try await store.add(try eve.publicIdentity(), name: "Eve", role: .member)
        _ = try await store.maintain()
        let approved = try await open(storage, as: eve, seen: await waiting.seenState)
        #expect(await approved.item(item.id)?.payload == .envFile(text: "DB=cyd"))
        #expect(await approved.rejectedFiles.isEmpty)
    }

    @Test func revisionsArrivingWithTheirAuthorsDemotionStillCount() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        let onCyd = try await open(storage, as: cyd)
        let seenByCyd = await onCyd.seenState
        // Bob saves, then is made a viewer, while Cyd's Mac is away.
        let onBob = try await open(storage, as: bob)
        let item = try await onBob.createItem(in: p.id, name: ".env", payload: .envFile(text: "DB=bob"))
        try await store.refresh()
        try await store.setRole(of: bob.id, to: .viewer)
        // Bob's own Mac keeps his revision, and so does Cyd's when both arrive together.
        try await onBob.refresh()
        let bobAgain = try await open(storage, as: bob, seen: await onBob.seenState)
        #expect(await bobAgain.item(item.id)?.payload == .envFile(text: "DB=bob"))
        let back = try await open(storage, as: cyd, seen: seenByCyd)
        #expect(await back.item(item.id)?.payload == .envFile(text: "DB=bob"))
    }

    @Test func aRemovalArrivingLateDoesntPauseTheVault() async throws {
        let (store, storage) = try await vault()
        let onAda = storage, elsewhere = MemoryStorage()
        await elsewhere.merge(await onAda.allFiles())
        // Ada, offline, removes Bob; meanwhile Bob renames himself and Cyd's Mac takes that in.
        try await store.remove(bob.id)
        try await Task.sleep(for: .milliseconds(5))
        try await (try await open(elsewhere, as: bob)).setName("Robert")
        let onCyd = try await open(elsewhere, as: cyd)
        let seen = await onCyd.seenState
        await elsewhere.merge(await onAda.allFiles())
        let later = try await open(elsewhere, as: cyd, seen: seen)
        #expect(await later.state.role(of: bob.id) == nil)
        #expect(!(await later.isTampered))
        let removal = try await eventPath(elsewhere) { if case .remove(bob.id) = $0.change { true } else { false } }
        let removalId = try #require(ULID(string: String(removal.dropFirst("members/".count).dropLast(".json".count))))
        #expect(await later.lateEvents.contains(removalId))
        _ = try await later.createProject(name: "still saving")
    }

    @Test func anEventReplacedInPlaceIsMissing() async throws {
        let (store, storage) = try await vault()
        try await store.remove(cyd.id)
        let seen = await store.seenState
        let removal = try await eventPath(storage) { if case .remove(cyd.id) = $0.change { true } else { false } }
        let path = VaultPath(removal.split(separator: "/").map(String.init))
        var spoiled = try MembershipEvent.decode(try await storage.read(path))
        spoiled.signature = Data(repeating: 0, count: 64)
        try await storage.writeReplace(path, data: try spoiled.encoded())
        #expect(try await open(storage, as: ada, seen: seen).isTampered)
    }

    @Test func aLockedStoreHasNoSeenStateToSave() async throws {
        let (store, _) = try await vault()
        #expect(await store.seenStateIfUnlocked != nil)
        await store.lock()
        #expect(await store.seenStateIfUnlocked == nil)
    }

    @Test func aRevisionDatedBeforeItsKeyIsRefused() async throws {
        let (store, storage) = try await vault()
        let p = try await store.createProject(name: "api")
        let epoch = try #require(await store.state.current)
        let key = try #require(try await keyFor(ada, storage: storage, epoch: epoch))
        let id = ULID(date: epoch.id.timestamp.addingTimeInterval(-7200))
        let rev = ProjectRevision(id: id, projectId: p.id, name: "old", tags: [], createdAt: Date(), device: mac)
        let data = try TeamRevisionFile.encode(rev, vaultId: store.vaultId, scope: .project, ownerId: p.id, revisionId: id, epoch: epoch.id, key: key, author: ada)
        #expect(throws: VaultError.self) {
            try TeamRevisionFile.decode(ProjectRevision.self, from: data, vaultId: store.vaultId, scope: .project, ownerId: p.id, revisionId: id, state: TeamState(header: store.header, events: []), keys: [epoch.id: key])
        }
    }

    @Test func savesUnderAKeyFromAFastClockStillCount() async throws {
        let (store, storage) = try await vault()
        // Ada's clock runs two hours fast when she rotates.
        let id = ULID(date: Date().addingTimeInterval(7200)), key = TeamKeys.newKey()
        let members = await store.state.members.values.map(\.identity)
        let rotation = try MembershipEvent.signed(.rotate(recipients: members.map(\.id), keyCommitment: TeamKeys.commitment(to: key, vaultId: store.vaultId, epoch: id), leftOut: []),
                                                  by: ada, vaultId: store.vaultId, id: id)
        try await storage.writeNew(VaultPath("members", "\(id.string).json"), data: try rotation.encoded())
        for m in members {
            try await storage.writeNew(VaultPath("keys", id.string, "\(m.id.uuidString).json"), data: try TeamKeys.wrap(key, for: m, vaultId: store.vaultId, epoch: id).encoded())
        }
        let onCyd = try await open(storage, as: cyd)
        #expect(await onCyd.state.current?.id == id)
        let p = try await onCyd.createProject(name: "api")
        let item = try await onCyd.createItem(in: p.id, name: ".env", payload: secret)
        let onBob = try await open(storage, as: bob)
        #expect(await onBob.item(item.id) != nil)
        #expect(await onBob.rejectedFiles.isEmpty)
    }

    @Test func junkFromTheFutureDoesntMakeEverythingLate() async throws {
        let (store, storage) = try await vault()
        let seen = await store.seenState
        let future = ULID(string: "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")!
        try await storage.writeNew(VaultPath("members", "\(future.string).json"),
                                   data: try MembershipEvent.signed(.setRole(member: cyd.id, role: .admin), by: cyd, vaultId: store.vaultId, id: future).encoded())
        let onAda = try await open(storage, as: ada, seen: seen)
        try await onAda.setRole(of: cyd.id, to: .viewer)
        let onBob = try await open(storage, as: bob, seen: await onAda.seenState)
        #expect(await onBob.lateEvents.isEmpty)
    }

    @Test func aKeyHPKERefusesIsNotAnIdentity() throws {
        // All zeros is a low-order X25519 point.
        var bad = try person("Eve").publicIdentity()
        bad.agreementKey = Data(count: 32)
        #expect(!bad.isValid)
    }

    @Test func aJunkLinkDoesntStopHistoryReachingNewcomers() async throws {
        let (store, storage) = try await vault()
        let e1 = try #require(await store.state.current).id
        let p = try await store.createProject(name: "api")
        let first = try await store.createItem(in: p.id, name: "first", payload: .envFile(text: "A=1"))
        // Squat the link the next rotation would write.
        try await store.remove(cyd.id)                        // rotates to E2 and links E2 → E1
        let e2 = try #require(await store.state.current).id
        _ = e2
        // Someone squats E3's future link path: rotate again, then check a newcomer still reads `first`.
        try await store.rotate()
        let e3 = try #require(await store.state.current).id
        let squat = VaultPath("keys", e3.string, "prev-\(e1.string).json")
        if try await !storage.exists(squat) { try await storage.writeNew(squat, data: Data("junk".utf8)) }
        let eve = person("Eve")
        try await store.add(try eve.publicIdentity(), name: "Eve", role: .member)
        _ = try await store.maintain()
        #expect(try await open(storage, as: eve).item(first.id) != nil)
    }
}

/// The epoch key `who` can unwrap from storage (what a member's Mac holds).
private func keyFor(_ who: UserIdentity, storage: MemoryStorage, epoch: TeamEpoch) async throws -> SymmetricKey? {
    let path = VaultPath("keys", epoch.id.string, "\(who.id.uuidString).json")
    guard try await storage.exists(path) else { return nil }
    return try TeamKeys.unwrap(try KeyWrap.decode(try await storage.read(path)), identity: who, vaultId: try await TeamVaultStore.open(storage: storage).vaultId, epoch: epoch)
}
