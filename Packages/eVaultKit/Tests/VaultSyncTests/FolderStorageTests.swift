import Testing
import Foundation
@testable import VaultCore
@testable import VaultSync

@Suite struct LocalFolderStorageTests {
    @Test func vaultOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalFolderStorage(root: dir)
        let kdf = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))
        let device = DeviceIdentity(id: UUID(), name: "t")
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: device, kdf: kdf)
        let p = try await store.createProject(name: "p")
        let item = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "X=1\n"))

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("vault.json").path))
        let itemDir = dir.appendingPathComponent("projects/\(p.id.uuidString)/items/\(item.id.uuidString)")
        let files = try FileManager.default.contentsOfDirectory(atPath: itemDir.path)
        #expect(files.count == 1 && files[0].hasSuffix(".evr"))

        // writeNew must never overwrite.
        let existing = VaultPath("projects", p.id.uuidString, "items", item.id.uuidString, files[0])
        await #expect(throws: VaultError.self) { try await storage.writeNew(existing, data: Data()) }

        let reopened = try await VaultStore.open(storage: storage, device: device)
        try await reopened.unlock(passphrase: "pw")
        #expect(await reopened.item(item.id)?.payload.primaryText == "X=1\n")
        #expect(await VaultStore.vaultExists(in: storage))
        #expect(await !VaultStore.vaultExists(in: LocalFolderStorage(root: dir.appendingPathComponent("nope"))))
    }

    @Test func listSeesICloudPlaceholders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evault-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(".ABC.evr.icloud"))
        try Data().write(to: dir.appendingPathComponent("DEF.evr"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        let names = try await LocalFolderStorage(root: dir.deletingLastPathComponent()).list(VaultPath(dir.lastPathComponent))
        #expect(Set(names) == ["ABC.evr", "DEF.evr"])
    }

    @Test func suggestedLocation() {
        let u = SyncLocations.suggestedVaultURL
        #expect(u.lastPathComponent == "eVault")
    }
}
