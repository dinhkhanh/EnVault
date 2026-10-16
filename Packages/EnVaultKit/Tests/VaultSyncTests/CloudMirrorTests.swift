import Testing
import Foundation
@testable import VaultCore
@testable import VaultSync

private let fastKDF = KDFParams(iterations: 1_000, salt: SecureRandom.bytes(32))
private let macA = DeviceIdentity(id: UUID(), name: "Mac A")
private let macB = DeviceIdentity(id: UUID(), name: "Mac B")

/// A simulated Mac: its own local vault folder, store, and mirror, all
/// talking to one shared in-memory "iCloud".
private struct Device {
    let root: URL
    let store: VaultStore
    let mirror: CloudMirror

    static func create(cloud: MemoryCloudTransport, passphrase: String) async throws -> (Device, UUID) {
        let root = tmp()
        let store = try await VaultStore.create(storage: LocalFolderStorage(root: root), passphrase: passphrase, device: macA, kdf: fastKDF)
        let vaultId = await store.vaultId
        let mirror = CloudMirror(vaultId: vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud)
        try await mirror.bootstrap()
        return (Device(root: root, store: store, mirror: mirror), vaultId)
    }

    /// Second device: download everything, then open.
    static func join(cloud: MemoryCloudTransport, vaultId: UUID, passphrase: String) async throws -> Device {
        let root = tmp()
        let mirror = CloudMirror(vaultId: vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud)
        try await mirror.pull()
        let store = try await VaultStore.open(storage: LocalFolderStorage(root: root), device: macB)
        try await store.unlock(passphrase: passphrase)
        return Device(root: root, store: store, mirror: mirror)
    }

    static func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("envault-cloud-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct CloudMirrorTests {
    @Test func secondDeviceGetsEverything() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        let item = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1"))
        let r = await a.mirror.sync()
        #expect(r.pushed == 3) // header + project meta + item
        #expect(await cloud.fileCount(vaultId) == 3)
        #expect(await cloud.subscribed.contains(vaultId))

        let b = try await Device.join(cloud: cloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }
        #expect(await b.store.item(item.id)?.payload.primaryText == "A=1")
        #expect(try await cloud.listVaults() == [vaultId])

        // Nothing to do on a second sync of either side.
        #expect(await a.mirror.sync() == (0, 0))
        #expect(await b.mirror.sync() == (0, 0))
    }

    /// Moving a vault from eVault's iCloud container to EnVault's: pull from one
    /// transport, push the same folder to another with fresh sync state.
    @Test func vaultMovesToAnotherContainer() async throws {
        let oldCloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: oldCloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        let item = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1"))
        try await a.store.updateItem(item.id, payload: .envFile(text: "A=2"))
        await a.mirror.sync()

        let root = Device.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let importState = root.appendingPathComponent(".sync/import.json")
        try await CloudMirror(vaultId: vaultId, localRoot: root, stateURL: importState, transport: oldCloud).pull()

        let newCloud = MemoryCloudTransport()
        let mirror = CloudMirror(vaultId: vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: newCloud)
        try await mirror.bootstrap()
        #expect(await mirror.sync().pushed == 4) // header + project meta + two item revisions
        let oldCount = await oldCloud.fileCount(vaultId)
        #expect(await newCloud.fileCount(vaultId) == oldCount)

        let b = try await Device.join(cloud: newCloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }
        #expect(await b.store.item(item.id)?.payload.primaryText == "A=2")
    }

    @Test func editsFlowBothWays() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        let item = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "v0"))
        await a.mirror.sync()
        let b = try await Device.join(cloud: cloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }

        try await b.store.updateItem(item.id, payload: .envFile(text: "v1 from B"))
        try await b.store.createItem(in: p.id, name: ".env.prod", payload: .envFile(text: "P=1"))
        #expect(await b.mirror.sync().pushed == 2)

        let pulled = await a.mirror.sync().pulled
        #expect(pulled == 2)
        try await a.store.refresh()
        #expect(await a.store.item(item.id)?.payload.primaryText == "v1 from B")
        #expect(await a.store.items(in: p.id).map(\.name) == [".env", ".env.prod"])
        #expect(await a.store.item(item.id)?.modifiedBy.name == "Mac B")
    }

    @Test func compactionPropagatesAsDeletion() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        let item = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "1"))
        try await a.store.updateItem(item.id, payload: .envFile(text: "2"))
        try await a.store.updateItem(item.id, payload: .envFile(text: "3"))
        await a.mirror.sync()
        let b = try await Device.join(cloud: cloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }
        #expect(await b.store.history(of: item.id).count == 3)

        try await a.store.compact(itemId: item.id)
        await a.mirror.sync()
        #expect(await cloud.fileCount(vaultId) == 3) // header, meta, one revision

        await b.mirror.sync()
        let reopened = try await VaultStore.open(storage: LocalFolderStorage(root: b.root), device: macB)
        try await reopened.unlock(passphrase: "pw")
        #expect(await reopened.history(of: item.id).count == 1)
        #expect(await reopened.item(item.id)?.payload.primaryText == "3")
    }

    @Test func passphraseChangeReachesOtherDevice() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "old")
        defer { a.cleanup() }
        try await a.store.createProject(name: "app")
        await a.mirror.sync()
        let b = try await Device.join(cloud: cloud, vaultId: vaultId, passphrase: "old")
        defer { b.cleanup() }

        try await a.store.changePassphrase(current: "old", new: "new")
        #expect(await a.mirror.sync().pushed == 1)
        #expect(await b.mirror.sync().pulled == 1)
        try await b.store.reloadHeader()
        await b.store.lock()
        await #expect(throws: VaultError.wrongPassphrase) { try await b.store.unlock(passphrase: "old") }
        try await b.store.unlock(passphrase: "new")
        #expect(await b.store.projects().map(\.name) == ["app"])
    }

    @Test func stateSurvivesRestartAndExpiredToken() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        try await a.store.createProject(name: "app")
        await a.mirror.sync()

        // New mirror instance over the same folder: reads persisted state, uploads nothing.
        let again = CloudMirror(vaultId: vaultId, localRoot: a.root, stateURL: a.root.appendingPathComponent(".sync/state.json"), transport: cloud)
        #expect(await again.sync() == (0, 0))
        #expect(await again.lastSync != nil)

        // Reset state: re-push is a no-op upstream (create-only), pull rewrites nothing.
        await again.reset()
        let r = await again.sync()
        #expect(r.pulled == 0)
        #expect(await cloud.fileCount(vaultId) == 2)
    }
}
