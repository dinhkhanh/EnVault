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

    /// Sync state written against one iCloud database (a debug build on CloudKit
    /// Development) must not stop uploads to another one that lacks the vault.
    @Test func missingZoneUploadsEverythingAgain() async throws {
        let devCloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: devCloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        let item = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1"))
        await a.mirror.sync()

        // Same folder and state file, other database: the zone is missing there.
        let prodCloud = MemoryCloudTransport()
        let mirror = CloudMirror(vaultId: vaultId, localRoot: a.root, stateURL: a.root.appendingPathComponent(".sync/state.json"), transport: prodCloud)
        #expect(await mirror.sync().pushed == 3) // header + project meta + item
        #expect(await prodCloud.fileCount(vaultId) == 3)

        let b = try await Device.join(cloud: prodCloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }
        #expect(await b.store.item(item.id)?.payload.primaryText == "A=1")
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

    @Test func filesOutsideProjectsSurviveASync() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        await a.mirror.sync()
        // Written by another client straight into the zone (a spike probe, a team identity…).
        try await cloud.upload([CloudFile(path: "spike/probe.json", data: Data("{}".utf8))], vaultId: vaultId, overwrite: false)
        await a.mirror.sync()
        await a.mirror.sync()
        #expect(try await cloud.fetchFile(path: "spike/probe.json", vaultId: vaultId) != nil)
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("spike/probe.json").path))

        // A file written locally outside projects/ goes up too.
        let local = a.root.appendingPathComponent("identities/me.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: local)
        await a.mirror.sync()
        #expect(try await cloud.fetchFile(path: "identities/me.json", vaultId: vaultId) != nil)
    }

    @Test func untrustedPathsAreIgnored() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        await a.mirror.sync()
        let outside = a.root.deletingLastPathComponent().appendingPathComponent("escaped-\(UUID().uuidString).txt")
        let evil = ["../\(outside.lastPathComponent)", "projects/../../\(outside.lastPathComponent)",
                    "projects//x.evr", "spike/.hidden", "spike/a|b.json", "team.json", "projects/p/notes.txt"]
        try await cloud.upload(evil.map { CloudFile(path: $0, data: Data("x".utf8)) }, vaultId: vaultId, overwrite: false)
        await a.mirror.sync()
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent("team.json").path))
        // Ignored, not deleted: a root-level file another client wrote stays in the cloud.
        #expect(try await cloud.fetchFile(path: "team.json", vaultId: vaultId) != nil)

        // Remote deletions of untrusted paths never touch local files.
        let victim = a.root.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: victim)
        defer { try? FileManager.default.removeItem(at: victim) }
        try await cloud.delete(paths: ["../\(victim.lastPathComponent)"], vaultId: vaultId)
        await a.mirror.sync()
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func strayLocalFilesStayLocal() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        let p = try await a.store.createProject(name: "app")
        _ = try await a.store.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1"))
        let dir = a.root.appendingPathComponent("projects/\(p.id.uuidString)")
        for name in ["Icon\r", "x.evr~", "notes.txt"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("x".utf8).write(to: a.root.appendingPathComponent("stray.json"))
        let before = await cloud.fileCount(vaultId)
        await a.mirror.sync()
        // header + project meta + item revision, and nothing else
        #expect(await cloud.fileCount(vaultId) == before + 3)
    }

    @Test func foreignHeaderIsIgnored() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        await a.mirror.sync()
        let other = try KeyHierarchy.createVault(passphrase: "attacker", kdf: fastKDF).header
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: try other.encoded())], vaultId: vaultId, overwrite: true)
        await a.mirror.sync()
        let local = try VaultHeader.decode(Data(contentsOf: a.root.appendingPathComponent(VaultHeader.fileName)))
        #expect(local.vaultId == vaultId)
        let reopened = try await VaultStore.open(storage: LocalFolderStorage(root: a.root), device: macA)
        try await reopened.unlock(passphrase: "pw")
    }

    @Test func aTeamHeaderIsNeverReplaced() async throws {
        let cloud = MemoryCloudTransport()
        let root = Device.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UserIdentity(id: UUID(), name: "Ada", createdAt: Date(),
                                 agreementKey: .init(), signingKey: .init())
        let store = try await TeamVaultStore.create(storage: LocalFolderStorage(root: root), owner: owner, title: "Acme", device: macA)
        let mirror = CloudMirror(vaultId: store.vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud)
        try await mirror.bootstrap()
        let ours = try Data(contentsOf: root.appendingPathComponent(VaultHeader.fileName))

        // A participant uploads a header they signed for the same vault id.
        let mallory = UserIdentity(id: UUID(), name: "Mallory", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        let swapped = try TeamHeader.create(owner: mallory, vaultId: store.vaultId).encoded()
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: swapped)], vaultId: store.vaultId, overwrite: true)
        await mirror.sync()
        #expect(try Data(contentsOf: root.appendingPathComponent(VaultHeader.fileName)) == ours)
        #expect(try await cloud.fetchFile(path: VaultHeader.fileName, vaultId: store.vaultId) == ours)   // put back
    }

    @Test func aRefusedHeaderDoesntVouchForTheOneKept() async throws {
        let cloud = MemoryCloudTransport()
        let owner = UserIdentity(id: UUID(), name: "Ada", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        let mallory = UserIdentity(id: UUID(), name: "Mallory", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        let vaultId = UUID()
        try await cloud.ensureVault(vaultId)
        let real = try TeamHeader.create(owner: owner, vaultId: vaultId).encoded()
        await cloud.signIn(as: "_ada")
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: real)], vaultId: vaultId, overwrite: true)
        await cloud.signIn(as: "_mallory")
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: try TeamHeader.create(owner: mallory, vaultId: vaultId).encoded())], vaultId: vaultId, overwrite: true)

        // A joiner downloads Mallory's header; the owner's Mac then puts the real one back.
        let root = Device.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let joiner = CloudMirror(vaultId: vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud)
        try await joiner.pull()
        #expect(await joiner.creator(of: VaultHeader.fileName) == nil)       // Ada created the record, Mallory changed it
        await cloud.signIn(as: "_ada")
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: real)], vaultId: vaultId, overwrite: true)
        // Retrying keeps the header on disk (Mallory's), so the owner mustn't be named as its writer.
        try await joiner.pull()
        #expect(try Data(contentsOf: root.appendingPathComponent(VaultHeader.fileName)) != real)
        #expect(await joiner.creator(of: VaultHeader.fileName) != "_ada")
    }

    @Test func joinRequestsRememberWhoUploadedThem() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        await cloud.signIn(as: "_bob")
        let request = "identities/\(UUID().uuidString)/\(ULID().string).json"
        try await cloud.upload([CloudFile(path: request, data: Data("{}".utf8), creator: "_mallory"),
                                CloudFile(path: "members/\(ULID().string).json", data: Data("{}".utf8))], vaultId: vaultId, overwrite: false)
        await a.mirror.sync()
        #expect(await a.mirror.creator(of: request) == "_bob")     // the server's record, not the uploader's claim
        #expect(await a.mirror.localFiles().contains(request))
    }

    @Test func aTeamVaultNeverDeletesAndPutsDeletedFilesBack() async throws {
        let cloud = MemoryCloudTransport()
        let root = Device.tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UserIdentity(id: UUID(), name: "Ada", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        let store = try await TeamVaultStore.create(storage: LocalFolderStorage(root: root), owner: owner, title: "Acme", device: macA)
        let mirror = CloudMirror(vaultId: store.vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud)
        try await mirror.bootstrap()
        await mirror.sync()
        let event = try #require(await mirror.localFiles().first { $0.hasPrefix("members/") })

        // A participant deletes a membership event in the zone.
        try await cloud.delete(paths: [event], vaultId: store.vaultId)
        await mirror.sync()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(event).path))   // kept here
        #expect(try await cloud.fetchFile(path: event, vaultId: store.vaultId) != nil)              // and put back

        // A file missing locally is never deleted from the zone either.
        try FileManager.default.removeItem(at: root.appendingPathComponent(event))
        await mirror.sync()
        #expect(try await cloud.fetchFile(path: event, vaultId: store.vaultId) != nil)
    }

    /// Ada's Mac hosts a team vault's zone; Cyd's Mac downloads it.
    private func hostedTeam(_ cloud: MemoryCloudTransport) async throws -> (host: CloudMirror, vaultId: UUID, roots: [URL]) {
        let root = Device.tmp()
        let owner = UserIdentity(id: UUID(), name: "Ada", createdAt: Date(), agreementKey: .init(), signingKey: .init())
        let store = try await TeamVaultStore.create(storage: LocalFolderStorage(root: root), owner: owner, title: "Acme", device: macA)
        await cloud.signIn(as: "_ada")
        let host = CloudMirror(vaultId: store.vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud, hostsZone: true)
        try await host.bootstrap()
        await host.sync()
        return (host, store.vaultId, [root])
    }

    private func mirror(_ vaultId: UUID, _ cloud: MemoryCloudTransport) -> (CloudMirror, URL) {
        let root = Device.tmp()
        return (CloudMirror(vaultId: vaultId, localRoot: root, stateURL: root.appendingPathComponent(".sync/state.json"), transport: cloud), root)
    }

    @Test func aTeamFileOverwrittenInPlaceIsPutBack() async throws {
        let cloud = MemoryCloudTransport()
        let (host, vaultId, roots) = try await hostedTeam(cloud)
        let event = try #require(await host.localFiles().first { $0.hasPrefix("members/") })
        let real = try #require(try await cloud.fetchFile(path: event, vaultId: vaultId))

        await cloud.signIn(as: "_bob")
        let (bob, bobRoot) = mirror(vaultId, cloud)
        let (cyd, cydRoot) = mirror(vaultId, cloud)
        defer { for r in roots + [bobRoot, cydRoot] { try? FileManager.default.removeItem(at: r) } }
        try await bob.pull()

        // A participant overwrites a membership event; Cyd's new Mac downloads the junk.
        await cloud.signIn(as: "_mallory")
        try await cloud.upload([CloudFile(path: event, data: Data("junk".utf8))], vaultId: vaultId, overwrite: true)
        await cloud.signIn(as: "_cyd")
        try await cyd.pull()

        // Bob's Mac puts its copy back. Cyd's came overwritten: it follows the zone
        // and never puts the junk back, though the record is no longer Ada's alone.
        await cloud.signIn(as: "_bob")
        await bob.sync()
        #expect(try await cloud.fetchFile(path: event, vaultId: vaultId) == real)
        await cloud.signIn(as: "_cyd")
        await cyd.sync()
        #expect(try await cloud.fetchFile(path: event, vaultId: vaultId) == real)
        #expect(try Data(contentsOf: cydRoot.appendingPathComponent(event)) == real)

        // Again, with the owner's Mac (the record's uploader) putting it back.
        await cloud.signIn(as: "_mallory")
        try await cloud.upload([CloudFile(path: event, data: Data("junk".utf8))], vaultId: vaultId, overwrite: true)
        await cloud.signIn(as: "_ada")
        await host.sync()
        #expect(try await cloud.fetchFile(path: event, vaultId: vaultId) == real)
    }

    @Test func aReSavedOrDeletedTeamHeaderComesBack() async throws {
        let cloud = MemoryCloudTransport()
        let (host, vaultId, roots) = try await hostedTeam(cloud)
        defer { for r in roots { try? FileManager.default.removeItem(at: r) } }
        let header = try #require(try await cloud.fetchFile(path: VaultHeader.fileName, vaultId: vaultId))

        // Mallory saves the same bytes again: a joiner couldn't tell it was the owner's.
        await cloud.signIn(as: "_mallory")
        try await cloud.upload([CloudFile(path: VaultHeader.fileName, data: header)], vaultId: vaultId, overwrite: true)
        await cloud.signIn(as: "_ada")
        await host.sync()
        let (joiner, joinerRoot) = mirror(vaultId, cloud)
        defer { try? FileManager.default.removeItem(at: joinerRoot) }
        try await joiner.pull()
        #expect(await joiner.creator(of: VaultHeader.fileName) == "_ada")

        // Deleted: the owner's Mac uploads it again.
        try await cloud.delete(paths: [VaultHeader.fileName], vaultId: vaultId)
        await host.sync()
        #expect(try await cloud.fetchFile(path: VaultHeader.fileName, vaultId: vaultId) == header)
    }

    @Test func onlyItsAuthorPutsBackADeletedJoinRequest() async throws {
        let cloud = MemoryCloudTransport()
        let (host, vaultId, roots) = try await hostedTeam(cloud)
        await cloud.signIn(as: "_bob")
        let (bob, bobRoot) = mirror(vaultId, cloud)
        defer { for r in roots + [bobRoot] { try? FileManager.default.removeItem(at: r) } }
        try await bob.pull()
        let request = "identities/\(UUID().uuidString)/\(ULID().string).json"
        try FileManager.default.createDirectory(at: bobRoot.appendingPathComponent(request).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bobRoot.appendingPathComponent(request))
        await bob.sync()
        await cloud.signIn(as: "_ada")
        await host.sync()

        // Deleted while Bob's Mac is away: Ada's Mac would become its uploader, so it leaves it.
        try await cloud.delete(paths: [request], vaultId: vaultId)
        await host.sync()
        #expect(try await cloud.fetchFile(path: request, vaultId: vaultId) == nil)
        await cloud.signIn(as: "_bob")
        await bob.sync()
        #expect(try await cloud.fetchFile(path: request, vaultId: vaultId) != nil)
        await cloud.signIn(as: "_ada")
        try await host.pull()
        #expect(await host.creator(of: request) == "_bob")
    }

    @Test func syncablePaths() {
        #expect(SyncPaths.isSyncable("vault.json"))
        let p = UUID().uuidString, i = UUID().uuidString, r = ULID().string
        #expect(SyncPaths.isSyncable("projects/\(p)/items/\(i)/\(r).evr"))
        #expect(SyncPaths.isSyncable("members/\(r).json") && SyncPaths.isSyncable("keys/\(r)/prev-\(r).json"))
        #expect(!SyncPaths.isSyncable("projects/\(p)/notes.txt"))
        // Twins that differ only in case would take the real file's place on a Mac's disk.
        #expect(!SyncPaths.isSyncable("projects/\(p.lowercased())/items/\(i)/\(r).evr"))
        #expect(!SyncPaths.isSyncable("projects/\(p)/ITEMS/\(i)/\(r).evr"))
        #expect(!SyncPaths.isSyncable("keys/\(r.lowercased())/\(i).json") && !SyncPaths.isSyncable("keys/\(r)/prev-\(r.lowercased()).json"))
        #expect(!SyncPaths.isSyncable("members/\(r).JSON") && !SyncPaths.isSyncable("spike/Probe.json"))
        #expect(!SyncPaths.isSyncable("devices/x.json"))
        #expect(!SyncPaths.isSyncable("../x"))
        #expect(!SyncPaths.isSyncable("spike/..") && !SyncPaths.isSyncable("spike/"))
        #expect(!SyncPaths.isSyncable("/spike/x.json"))
        #expect(!SyncPaths.isSyncable("spike/caf\u{e9}.json"))
    }

    @Test func identityReachesTheSecondMac() async throws {
        let cloud = MemoryCloudTransport()
        let (a, vaultId) = try await Device.create(cloud: cloud, passphrase: "pw")
        defer { a.cleanup() }
        let me = try await a.store.createIdentity(name: "Ada")
        await a.mirror.sync()
        let b = try await Device.join(cloud: cloud, vaultId: vaultId, passphrase: "pw")
        defer { b.cleanup() }
        #expect(try await b.store.identity()?.safetyCode == me.safetyCode)
        // Releases up to 0.7.1 keep only projects/**/*.evr; the identity sits inside that.
        let path = try #require(await a.mirror.localFiles().first { $0.contains("/identity/") })
        #expect(path.hasPrefix("projects/") && path.hasSuffix(".evr"))
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
