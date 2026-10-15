import Testing
import Foundation
@testable import VaultCore

private let fastKDF = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))
private let mac1 = DeviceIdentity(id: UUID(), name: "Mac 1")
private let mac2 = DeviceIdentity(id: UUID(), name: "Mac 2")

@Suite struct VaultStoreTests {
    @Test func createOpenUnlock() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        #expect(await store.isUnlocked)
        let p = try await store.createProject(name: "my-saas")
        try await store.createItem(in: p.id, name: ".env.local", payload: .envFile(text: "A=1\n"))

        let reopened = try await VaultStore.open(storage: storage, device: mac1)
        #expect(await !reopened.isUnlocked)
        await #expect(throws: VaultError.wrongPassphrase) { try await reopened.unlock(passphrase: "nope") }
        try await reopened.unlock(passphrase: "pw")
        let projects = await reopened.projects()
        #expect(projects.map(\.name) == ["my-saas"])
        #expect(projects[0].itemCount == 1)
        let items = await reopened.items(in: p.id)
        #expect(items[0].payload == .envFile(text: "A=1\n"))
    }

    @Test func createRefusesExistingVault() async throws {
        let storage = MemoryStorage()
        _ = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        await #expect(throws: VaultError.vaultAlreadyExists) { _ = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF) }
    }

    @Test func historyAndRestore() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        let item = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "V=1"))
        try await store.updateItem(item.id, payload: .envFile(text: "V=2"))
        try await store.updateItem(item.id, payload: .envFile(text: "V=2")) // no-op, no new revision
        try await store.updateItem(item.id, payload: .envFile(text: "V=3"))
        let history = await store.history(of: item.id)
        #expect(history.map { $0.payload.primaryText } == ["V=3", "V=2", "V=1"])
        try await store.restore(history.last!)
        #expect(await store.item(item.id)?.payload.primaryText == "V=1")
        #expect(await store.history(of: item.id).count == 4)
    }

    @Test func deleteIsTombstoneAndRestorable() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        let item = try await store.createItem(in: p.id, name: "k", payload: .secret(value: "v", notes: ""))
        try await store.deleteItem(item.id)
        #expect(await store.item(item.id) == nil)
        #expect(await store.items(in: p.id).isEmpty)
        let last = await store.history(of: item.id).first!
        #expect(last.deleted)
        try await store.restore(await store.history(of: item.id)[1])
        #expect(await store.item(item.id)?.payload.primaryText == "v")
    }

    @Test func deleteProjectTombstonesItems() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        try await store.createItem(in: p.id, name: "a", payload: .note(markdown: "x"))
        try await store.deleteProject(p.id)
        #expect(await store.projects().isEmpty)
        #expect(await store.allItems().isEmpty)
    }

    @Test func changePassphrase() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "old", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        await #expect(throws: VaultError.wrongPassphrase) { try await store.changePassphrase(current: "wrong", new: "new") }
        try await store.changePassphrase(current: "old", new: "new")
        let reopened = try await VaultStore.open(storage: storage, device: mac1)
        try await reopened.unlock(passphrase: "new")
        #expect(await reopened.project(p.id) != nil)
    }

    @Test func compactKeepsLatest() async throws {
        let storage = MemoryStorage()
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "p")
        let item = try await store.createItem(in: p.id, name: "e", payload: .envFile(text: "1"))
        try await store.updateItem(item.id, payload: .envFile(text: "2"))
        try await store.updateItem(item.id, payload: .envFile(text: "3"))
        try await store.compact(itemId: item.id)
        #expect(await store.history(of: item.id).count == 1)
        let files = await storage.allFiles().keys.filter { $0.contains(item.id.uuidString) }
        #expect(files.count == 1)
        let reopened = try await VaultStore.open(storage: storage, device: mac1)
        try await reopened.unlock(passphrase: "pw")
        #expect(await reopened.item(item.id)?.payload.primaryText == "3")
    }

    @Test func lockClearsEverything() async throws {
        let store = try await VaultStore.create(storage: MemoryStorage(), passphrase: "pw", device: mac1, kdf: fastKDF)
        try await store.createProject(name: "p")
        await store.lock()
        #expect(await store.projects().isEmpty)
        await #expect(throws: VaultError.locked) { try await store.refresh() }
    }
}

/// Two Macs share one synced folder. Each has its own MemoryStorage; "sync"
/// copies new files between them, exactly like iCloud Drive would.
@Suite struct TwoDeviceSyncTests {
    @Test func offlineEditsMergeLatestWins() async throws {
        let s1 = MemoryStorage()
        let a = try await VaultStore.create(storage: s1, passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await a.createProject(name: "shared")
        let item = try await a.createItem(in: p.id, name: ".env", payload: .envFile(text: "V=a0"))

        // Device 2 receives the folder and unlocks with the passphrase.
        let s2 = MemoryStorage()
        await s2.merge(await s1.allFiles())
        let b = try await VaultStore.open(storage: s2, device: mac2)
        try await b.unlock(passphrase: "pw")
        #expect(await b.item(item.id)?.payload.primaryText == "V=a0")

        // Both edit offline; device 2 edits last.
        try await a.updateItem(item.id, payload: .envFile(text: "V=a1"))
        try? await Task.sleep(for: .milliseconds(5))
        try await b.updateItem(item.id, payload: .envFile(text: "V=b1"))
        try await b.createItem(in: p.id, name: ".env.prod", payload: .envFile(text: "P=1"))

        // Sync both ways, then refresh.
        let f1 = await s1.allFiles(), f2 = await s2.allFiles()
        await s1.merge(f2); await s2.merge(f1)
        #expect(try await a.refresh())
        #expect(try await b.refresh())
        #expect(try await a.refresh() == false) // idempotent

        #expect(await a.item(item.id)?.payload.primaryText == "V=b1")
        #expect(await b.item(item.id)?.payload.primaryText == "V=b1")
        #expect(await a.history(of: item.id).map { $0.payload.primaryText } == ["V=b1", "V=a1", "V=a0"])
        #expect(await a.items(in: p.id).map(\.name) == [".env", ".env.prod"])
        #expect(await a.item(item.id)?.modifiedBy.name == "Mac 2")
    }

    @Test func noFileIsEverOverwritten() async throws {
        let s = MemoryStorage()
        let a = try await VaultStore.create(storage: s, passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await a.createProject(name: "p")
        let item = try await a.createItem(in: p.id, name: "e", payload: .envFile(text: "1"))
        let before = await s.allFiles()
        try await a.updateItem(item.id, payload: .envFile(text: "2"))
        try await a.updateProject(p.id, name: "renamed")
        let after = await s.allFiles()
        for (k, v) in before { #expect(after[k] == v) }
        #expect(after.count == before.count + 2)
    }

    @Test func folderUnlockReadsInBatchesAndReportsProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "evault-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = LocalFolderStorage(root: dir)
        let store = try await VaultStore.create(storage: storage, passphrase: "pw", device: mac1, kdf: fastKDF)
        let p = try await store.createProject(name: "P")
        for i in 0..<30 {
            let item = try await store.createItem(in: p.id, name: "i\(i)", payload: .envFile(text: "A=0"))
            for r in 1...4 { _ = try await store.updateItem(item.id, payload: .envFile(text: "A=\(r)")) }
        }

        let reopened = try await VaultStore.open(storage: storage, device: mac1)
        let reports = Reports()
        try await reopened.unlock(passphrase: "pw") { done, total in reports.add(done, total) }
        let seen = reports.all
        #expect(seen.first?.0 == 0)
        #expect(seen.last.map { $0.0 == $0.1 } == true)
        #expect(seen.last?.1 == 1 + 30 * 5)   // project meta + 30 items x 5 revisions
        let items = await reopened.items(in: p.id)
        #expect(items.count == 30)
        #expect(items.allSatisfy { $0.revisionCount == 5 && $0.payload == .envFile(text: "A=4") })
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { lock.withLock { list.append((done, total)) } }
    var all: [(Int, Int)] { lock.withLock { list } }
}
