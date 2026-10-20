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
private func open(_ storage: MemoryStorage, as who: UserIdentity, seen: Set<ULID> = []) async throws -> TeamVaultStore {
    let store = try await TeamVaultStore.open(storage: storage, device: mac)
    try await store.unlock(identity: who, seenEvents: seen)
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
        let again = try await open(macs[ada.id]!, as: ada, seen: await onAda.knownEvents)
        #expect(await again.lateEvents.isEmpty)
        await again.dismissLate(late)
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
