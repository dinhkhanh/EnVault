import Testing
import Foundation
@testable import VaultCore

private let fastKDF = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))
private let mac1 = DeviceIdentity(id: UUID(), name: "Mac 1")
private let mac2 = DeviceIdentity(id: UUID(), name: "Mac 2")

@Suite struct IdentityTests {
    @Test func identityFollowsTheVault() async throws {
        let storage = MemoryStorage()
        let a = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        #expect(try await a.identity() == nil)
        let made = try await a.createIdentity(name: "Ada")
        #expect(try await a.createIdentity(name: "Other").id == made.id) // idempotent

        let b = try await VaultStore.open(storage: storage, device: mac2)
        try await b.unlock(passphrase: "pw")
        let read = try #require(try await b.identity())
        #expect(read.id == made.id && read.name == "Ada")
        #expect(read.agreementKey.rawRepresentation == made.agreementKey.rawRepresentation)
        #expect(read.signingKey.rawRepresentation == made.signingKey.rawRepresentation)
        #expect(read.safetyCode == made.safetyCode)
    }

    @Test func identityIsNotAProject() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        try await store.createProject(name: "app")
        try await store.createIdentity(name: "Ada")
        #expect(await store.projects().map(\.name) == ["app"])
        #expect(await store.projects(includeDeleted: true).count == 1)
    }

    @Test func renameKeepsKeysAndCode() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        let before = try await store.createIdentity(name: "Ada")
        let after = try await store.renameIdentity("Ada Lovelace")
        #expect(after.id == before.id && after.name == "Ada Lovelace")
        #expect(after.safetyCode == before.safetyCode)
        #expect(try await store.identity()?.name == "Ada Lovelace")
    }

    @Test func twoOfflineMacsAgreeOnTheOlderIdentity() async throws {
        let s1 = MemoryStorage()
        let a = try await VaultStore.create(storage: s1, passphrase: "pw", device: mac1, kdf: fastKDF)
        let s2 = MemoryStorage()
        await s2.merge(await s1.allFiles())
        let b = try await VaultStore.open(storage: s2, device: mac2)
        try await b.unlock(passphrase: "pw")

        let older = try await a.createIdentity(name: "on Mac 1")
        try? await Task.sleep(for: .milliseconds(5))
        _ = try await b.createIdentity(name: "on Mac 2")

        let f1 = await s1.allFiles(), f2 = await s2.allFiles()
        await s1.merge(f2); await s2.merge(f1)
        try await a.refresh(); try await b.refresh()
        #expect(try await a.identity()?.id == older.id)
        #expect(try await b.identity()?.id == older.id)
    }

    @Test func identityFileIsBoundToItsPath() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        let id = try await store.createIdentity(name: "Ada")
        // Copy the revision under another identity id: the AAD no longer matches.
        let files = await storage.allFiles()
        let (path, data) = try #require(files.first { $0.key.contains("/identity/") })
        let moved = path.replacingOccurrences(of: id.id.uuidString, with: UUID().uuidString)
        let other = MemoryStorage()
        await other.merge(files.filter { $0.key != path }.merging([moved: data]) { a, _ in a })
        let reopened = try await VaultStore.open(storage: other, device: mac1)
        await #expect(throws: VaultError.self) { try await reopened.unlock(passphrase: "pw") }
    }

    @Test func publicIdentityIsSelfSigned() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        let me = try await store.createIdentity(name: "Ada")
        let pub = try me.publicIdentity()
        #expect(pub.isValid)
        #expect(pub.safetyCode == me.safetyCode)

        var renamed = pub; renamed.name = "Mallory"
        #expect(renamed.isValid && renamed.unnamed.isValid) // names are not signed
        var moved = pub; moved.id = UUID()
        #expect(!moved.isValid)
        var swapped = pub; swapped.agreementKey = Data(repeating: 9, count: 32)
        #expect(!swapped.isValid)

        let decoded = try JSONDecoder().decode(PublicIdentity.self, from: try JSONEncoder().encode(pub))
        #expect(decoded == pub && decoded.isValid)
    }

    @Test func safetyCodeShape() {
        let code = SafetyCode.code(agreementKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32))
        let groups = code.split(separator: " ")
        #expect(groups.count == 6 && groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
        #expect(code == SafetyCode.code(agreementKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32)))
        #expect(code != SafetyCode.code(agreementKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 3, count: 32)))
    }
}

@Suite struct TeamRecordTests {
    @Test func teamsFollowThePersonAndKeepTheirPin() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        let vault = UUID()
        let pin = Data(repeating: 1, count: 32)
        try await store.saveTeam(TeamRecord(vaultId: vault, ownerKey: pin, zoneOwner: "_abc"))
        try await store.saveTeam(TeamRecord(vaultId: vault, ownerKey: Data(repeating: 2, count: 32), zoneOwner: "_abc"))

        let other = try await VaultStore.open(storage: storage, device: mac2)
        try await other.unlock(passphrase: "pw")
        let record = try #require(await other.teams().first)
        #expect(record.vaultId == vault && record.ownerKey == pin && record.zoneOwner == "_abc")
        #expect(await other.projects().isEmpty)

        var left = record; left.left = true
        try await other.saveTeam(left)
        #expect(await other.teams().isEmpty)
        #expect(await other.pinnedOwnerKey(for: vault) == pin)       // rejoining checks the same owner
    }
}
