import Testing
import Foundation
@testable import VaultCore

private let fastKDF = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))

@Suite struct RecoveryKeyTests {
    @Test func formatAndNormalize() {
        let k = RecoveryKey.generate()
        #expect(k.hasPrefix("EVLT-"))
        #expect(k.count == "EVLT-".count + 32 + 7)
        let c = RecoveryKey.normalize(k)!
        #expect(c.count == 32)
        #expect(RecoveryKey.normalize(k.lowercased().replacingOccurrences(of: "-", with: " ")) == c)
        #expect(RecoveryKey.normalize("evlt " + c.lowercased()) == c)
        #expect(RecoveryKey.normalize("too short") == nil)
        #expect(RecoveryKey.display(c) == k)
        #expect(Set((0..<200).map { _ in RecoveryKey.generate() }).count == 200)
    }

    @Test func recoverAndResetPassphrase() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "forgotten", device: DeviceIdentity(id: UUID(), name: "t"), kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        #expect(await !store.hasRecoveryKey)
        let key = try await store.createRecoveryKey()
        #expect(await store.hasRecoveryKey)

        let reopened = try await VaultStore.open(storage: storage, device: DeviceIdentity(id: UUID(), name: "t"))
        await #expect(throws: VaultError.wrongRecoveryKey) { try await reopened.unlock(recoveryKey: "EVLT-" + String(repeating: "A", count: 32)) }
        await #expect(throws: VaultError.wrongRecoveryKey) { try await reopened.unlock(recoveryKey: "nonsense") }
        try await reopened.unlock(recoveryKey: key.lowercased())
        #expect(await reopened.project(p.id) != nil)
        try await reopened.resetPassphrase(new: "brand new")

        let third = try await VaultStore.open(storage: storage, device: DeviceIdentity(id: UUID(), name: "t"))
        await #expect(throws: VaultError.wrongPassphrase) { try await third.unlock(passphrase: "forgotten") }
        try await third.unlock(passphrase: "brand new")
        #expect(await third.hasRecoveryKey) // recovery survives a passphrase reset
        try await third.unlock(recoveryKey: key)
    }

    @Test func removeAndReplace() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: DeviceIdentity(id: UUID(), name: "t"), kdf: fastKDF)
        let k1 = try await store.createRecoveryKey()
        let k2 = try await store.createRecoveryKey()
        #expect(k1 != k2)
        let r = try await VaultStore.open(storage: storage, device: DeviceIdentity(id: UUID(), name: "t"))
        await #expect(throws: VaultError.wrongRecoveryKey) { try await r.unlock(recoveryKey: k1) }
        try await r.unlock(recoveryKey: k2)
        try await store.removeRecoveryKey()
        let r2 = try await VaultStore.open(storage: storage, device: DeviceIdentity(id: UUID(), name: "t"))
        await #expect(throws: VaultError.noRecoveryKey) { try await r2.unlock(recoveryKey: k2) }
    }

    @Test func oldHeadersStillDecode() throws {
        let (h, _) = try KeyHierarchy.createVault(passphrase: "x", kdf: fastKDF)
        var json = try JSONSerialization.jsonObject(with: try h.encoded()) as! [String: Any]
        json["recovery"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(try VaultHeader.decode(data).recovery == nil)
    }
}
