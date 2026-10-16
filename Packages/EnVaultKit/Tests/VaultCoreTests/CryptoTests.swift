import Testing
import Foundation
@testable import VaultCore

@Suite struct ULIDTests {
    @Test func sortsByTime() {
        let a = ULID(date: Date(timeIntervalSince1970: 1_000))
        let b = ULID(date: Date(timeIntervalSince1970: 2_000))
        #expect(a < b)
        #expect(a.string.count == 26)
        #expect(abs(a.timestamp.timeIntervalSince1970 - 1_000) < 0.001)
    }

    @Test func roundTripsThroughString() {
        let u = ULID()
        #expect(ULID(string: u.string) == u)
        #expect(ULID(string: "not a ulid") == nil)
        #expect(ULID(string: String(repeating: "Z", count: 26)) == nil) // overflow
    }

    @Test func uniqueAndMonotonic() {
        let ids = (0..<1000).map { _ in ULID() }
        #expect(Set(ids.map(\.string)).count == 1000)
        #expect(ids == ids.sorted())
    }
}

@Suite struct KeyHierarchyTests {
    let fastKDF = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))

    @Test func createAndUnlock() throws {
        let (header, vk) = try KeyHierarchy.createVault(passphrase: "correct horse", kdf: fastKDF)
        let unlocked = try KeyHierarchy.unlock(header: header, passphrase: "correct horse")
        #expect(unlocked == vk)
    }

    @Test func wrongPassphraseFails() throws {
        let (header, _) = try KeyHierarchy.createVault(passphrase: "a", kdf: fastKDF)
        #expect(throws: VaultError.wrongPassphrase) { try KeyHierarchy.unlock(header: header, passphrase: "b") }
    }

    @Test func rewrapKeepsVaultKey() throws {
        let (header, vk) = try KeyHierarchy.createVault(passphrase: "old", kdf: fastKDF)
        let h2 = try KeyHierarchy.rewrap(header: header, vaultKey: vk, newPassphrase: "new", kdf: fastKDF)
        #expect(try KeyHierarchy.unlock(header: h2, passphrase: "new") == vk)
        #expect(throws: VaultError.wrongPassphrase) { try KeyHierarchy.unlock(header: h2, passphrase: "old") }
        #expect(h2.vaultId == header.vaultId)
    }

    @Test func headerIsStableJSON() throws {
        let (header, _) = try KeyHierarchy.createVault(passphrase: "x", kdf: fastKDF)
        let data = try header.encoded()
        let back = try VaultHeader.decode(data)
        #expect(back.vaultId == header.vaultId)
        #expect(back.kdf == header.kdf)
        #expect(back.wrappedVaultKey == header.wrappedVaultKey)
        #expect(abs(back.createdAt.timeIntervalSince(header.createdAt)) < 1)
        #expect(String(data: data, encoding: .utf8)!.contains("\"formatVersion\" : 1"))
    }

    @Test func futureFormatRejected() throws {
        let (header, _) = try KeyHierarchy.createVault(passphrase: "x", kdf: fastKDF)
        var h = header; h.formatVersion = 99
        #expect(throws: VaultError.unsupportedFormatVersion(99)) { try VaultHeader.decode(try h.encoded()) }
    }
}

@Suite struct RevisionFileTests {
    let vk = VaultKey.random()
    let vaultId = UUID()
    let device = DeviceIdentity(id: UUID(), name: "Test Mac")

    @Test func roundTrip() throws {
        let rev = ItemRevision(itemId: UUID(), projectId: UUID(), name: ".env", tags: ["a"], payload: .envFile(text: "A=1\n"), createdAt: Date(), device: device)
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        #expect(data.prefix(4) == Data("EVR1".utf8))
        let back = try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        #expect(back.payload == rev.payload)
        #expect(back.name == rev.name)
        #expect(back.id == rev.id)
    }

    @Test func boundToOwnerAndRevision() throws {
        let rev = ItemRevision(itemId: UUID(), projectId: UUID(), name: "x", tags: [], payload: .secret(value: "s", notes: ""), createdAt: Date(), device: device)
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        #expect(throws: VaultError.self) {
            _ = try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: UUID(), revisionId: rev.id, key: vk)
        }
        #expect(throws: VaultError.self) {
            _ = try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: ULID(), key: vk)
        }
        #expect(throws: VaultError.self) {
            _ = try RevisionFile.decode(ItemRevision.self, from: data, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: .random())
        }
    }

    @Test func ciphertextHidesNames() throws {
        let rev = ItemRevision(itemId: UUID(), projectId: UUID(), name: "SUPER_SECRET_NAME", tags: [], payload: .envFile(text: "TOKEN=hunter2"), createdAt: Date(), device: device)
        let data = try RevisionFile.encode(rev, vaultId: vaultId, scope: .item, ownerId: rev.itemId, revisionId: rev.id, key: vk)
        #expect(!data.contains(Data("SUPER_SECRET_NAME".utf8)))
        #expect(!data.contains(Data("hunter2".utf8)))
    }

    @Test func unknownPayloadKindRoundTrips() throws {
        let p = ItemPayload.unknown(kind: "sshKey", fields: ["private": "---", "public": "ssh-ed25519"])
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(ItemPayload.self, from: data) == p)
        #expect(p.kind == .unknown("sshKey"))
    }
}
