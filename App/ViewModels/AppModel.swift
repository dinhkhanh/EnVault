import SwiftUI
import VaultCore
import VaultSync
import ToolKit

/// Single source of truth for the UI. Wraps the `VaultStore` actor and keeps
/// value-type snapshots that SwiftUI can render synchronously.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case noVault              // no vault chosen yet
        case locked
        case unlocked
    }

    /// Where the vault's files are synchronised.
    enum SyncMode: Equatable {
        case folder               // any folder (iCloud Drive, Dropbox, git…)
        case iCloud               // local copy in the app container, mirrored via CloudKit
    }

    private(set) var phase: Phase = .loading
    private(set) var syncMode: SyncMode = .folder
    private(set) var vaultURL: URL?
    private(set) var vaultId: UUID?
    private(set) var projects: [Project] = []
    private(set) var items: [Item] = []
    private(set) var lastRefresh: Date?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastCloudSync: Date?
    var errorMessage: String?
    var biometricsAvailable: Bool { KeychainVaultKeyStore.biometricsAvailable }
    private(set) var hasBiometricKey = false
    private(set) var hasRecoveryKey = false
    /// Non-nil while an unlock runs; drives the lock screen's progress.
    private(set) var unlockProgress: UnlockProgress?

    enum UnlockProgress: Equatable {
        case checking                                // deriving the key from the passphrase
        case decrypting(done: Int, total: Int)       // reading and decrypting revisions
    }
    /// A freshly generated recovery key the UI must show once, then clear.
    var pendingRecoveryKey: String?
    /// Set after a recovery-key unlock: the user must choose a new passphrase.
    var needsPassphraseReset = false

    /// True when this build carries the iCloud entitlement (signed configurations).
    /// Debug builds launched with `-fakeCloud YES` simulate it with an in-memory cloud.
    let cloudAvailable: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeCloud") { return true }
        #endif
        return CloudKitAvailability.isEntitled
    }()

    var selectedProjectId: UUID?
    var selectedItemId: UUID?
    var selectedToolId: String?
    var searchText = ""

    @ObservationIgnored private var store: VaultStore?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var mirror: CloudMirror?
    @ObservationIgnored private var cloudTimer: Task<Void, Never>?
    @ObservationIgnored private var pushDebounce: Task<Void, Never>?
    @ObservationIgnored private var autoLock: AutoLock!
    @ObservationIgnored private let keychain = KeychainVaultKeyStore()
    @ObservationIgnored private lazy var cloud: CloudVaultTransport = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeCloud") { return MemoryCloudTransport() }
        #endif
        return CloudKitTransport()
    }()

    let tools = ToolRegistry.all

    private static let iCloudVaultKey = "dk.dinhkhanh.evault.iCloudVaultId"

    init() {
        Prefs.registerDefaults()
        autoLock = AutoLock { [weak self] in self?.lock() }
    }

    // MARK: - Derived

    func items(in projectId: UUID) -> [Item] { items.filter { $0.projectId == projectId } }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectId } }
    var selectedItem: Item? { items.first { $0.id == selectedItemId } }
    var isInICloudDrive: Bool { syncMode == .folder && (vaultURL.map(SyncLocations.isInsideICloudDrive) ?? false) }

    // MARK: - Startup

    func start() async {
        guard phase == .loading else { return }
        #if DEBUG
        // Dev/testing: `eVault -vaultPath <dir> [-passphrase <pw>]` opens or creates a vault directly.
        // `-fakeCloud YES -createICloud YES -passphrase <pw>` creates a vault in the in-memory cloud.
        if UserDefaults.standard.bool(forKey: "createICloud"), let pw = UserDefaults.standard.string(forKey: "passphrase") {
            await createVaultInICloud(passphrase: pw)
            if phase != .loading { return }
        }
        if let path = UserDefaults.standard.string(forKey: "vaultPath") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if await VaultStore.vaultExists(in: LocalFolderStorage(root: url)) {
                await openVault(at: url, mode: .folder)
            } else if let pw = UserDefaults.standard.string(forKey: "passphrase") {
                await createVault(at: url, passphrase: pw, mode: .folder)
            }
            if phase != .loading { return }
        }
        #endif
        if cloudAvailable, let s = UserDefaults.standard.string(forKey: Self.iCloudVaultKey), let id = UUID(uuidString: s) {
            await openICloudVault(id, download: false)
            if phase != .loading { return }
        }
        if let url = VaultLocation.restore() {
            await openVault(at: url, mode: .folder)
        } else {
            phase = .noVault
        }
    }

    /// Opens (locked) the vault in `url`. Shows an error if there is none.
    func openVault(at url: URL, mode: SyncMode) async {
        do {
            let storage = LocalFolderStorage(root: url)
            let s = try await VaultStore.open(storage: storage)
            store = s
            vaultURL = url
            vaultId = await s.vaultId
            syncMode = mode
            if mode == .folder { try VaultLocation.save(url) } else { UserDefaults.standard.set(vaultId!.uuidString, forKey: Self.iCloudVaultKey) }
            hasBiometricKey = keychain.hasCachedKey(vaultId: vaultId!)
            hasRecoveryKey = await s.hasRecoveryKey
            phase = .locked
            errorMessage = nil
            startWatching()
            if mode == .iCloud { startCloud() }
        } catch {
            errorMessage = error.localizedDescription
            if phase == .loading { phase = .noVault }
        }
    }

    func createVault(at url: URL, passphrase: String, mode: SyncMode) async {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let storage = LocalFolderStorage(root: url)
            let s = try await VaultStore.create(storage: storage, passphrase: passphrase)
            store = s
            vaultURL = url
            vaultId = await s.vaultId
            syncMode = mode
            if mode == .folder { try VaultLocation.save(url) } else { UserDefaults.standard.set(vaultId!.uuidString, forKey: Self.iCloudVaultKey) }
            hasBiometricKey = false
            errorMessage = nil
            pendingRecoveryKey = try await s.createRecoveryKey()
            hasRecoveryKey = true
            startWatching()
            if mode == .iCloud {
                startCloud()
                try await mirror?.bootstrap()
            }
            await becameUnlocked()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forget the current vault (does not delete any files).
    func closeVault() {
        lock()
        stopWatching()
        stopCloud()
        VaultLocation.forget()
        UserDefaults.standard.removeObject(forKey: Self.iCloudVaultKey)
        store = nil
        vaultURL = nil
        vaultId = nil
        syncMode = .folder
        phase = .noVault
    }

    // MARK: - iCloud (CloudKit) mode

    private static func localRoot(for vaultId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("eVault/Vaults/\(vaultId.uuidString)", isDirectory: true)
    }
    private static func stateURL(for vaultId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("eVault/SyncState/\(vaultId.uuidString).json")
    }

    func createVaultInICloud(passphrase: String) async {
        // The vault id is assigned by VaultStore.create, so create in a temp folder and rename.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tmp = support.appendingPathComponent("eVault/Vaults/new-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let s = try await VaultStore.create(storage: LocalFolderStorage(root: tmp), passphrase: passphrase)
            let vid = await s.vaultId
            let final = Self.localRoot(for: vid)
            try FileManager.default.moveItem(at: tmp, to: final)
            await openVault(at: final, mode: .iCloud)
            try await mirror?.bootstrap()
            await syncNow()
            // openVault leaves us locked; unlock with the passphrase we just set.
            await unlock(passphrase: passphrase, rememberWithBiometrics: false)
            pendingRecoveryKey = await createRecoveryKey()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    struct CloudVaultSummary: Identifiable, Sendable {
        let id: UUID
        let createdAt: Date?
    }

    /// Vaults in the iCloud account, newest first.
    func listICloudVaults() async -> [CloudVaultSummary] {
        do {
            var out: [CloudVaultSummary] = []
            for id in try await cloud.listVaults() {
                let header = try await cloud.fetchFile(path: VaultHeader.fileName, vaultId: id).flatMap { try? VaultHeader.decode($0) }
                out.append(CloudVaultSummary(id: id, createdAt: header?.createdAt))
            }
            return out.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Downloads (if needed) and opens a vault from the iCloud account.
    func openICloudVault(_ id: UUID, download: Bool = true) async {
        let root = Self.localRoot(for: id)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let m = CloudMirror(vaultId: id, localRoot: root, stateURL: Self.stateURL(for: id), transport: cloud)
            let haveLocal = await VaultStore.vaultExists(in: LocalFolderStorage(root: root))
            if download || !haveLocal {
                syncStatus = .syncing
                try await m.pull()
                syncStatus = .idle
            }
            await openVault(at: root, mode: .iCloud)
        } catch {
            syncStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
            if phase == .loading { phase = .noVault }
        }
    }

    private func startCloud() {
        guard cloudAvailable, let vaultId, let vaultURL else { return }
        mirror = CloudMirror(vaultId: vaultId, localRoot: vaultURL, stateURL: Self.stateURL(for: vaultId), transport: cloud)
        cloudTimer?.cancel()
        cloudTimer = Task { [weak self] in
            await self?.syncNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.syncNow()
            }
        }
    }

    private func stopCloud() {
        cloudTimer?.cancel(); cloudTimer = nil
        pushDebounce?.cancel(); pushDebounce = nil
        mirror = nil
        syncStatus = .idle
        lastCloudSync = nil
    }

    /// Full pull + push. Safe to call any time, locked or not.
    func syncNow() async {
        guard let mirror else { return }
        syncStatus = .syncing
        let r = await mirror.sync()
        syncStatus = await mirror.status
        lastCloudSync = await mirror.lastSync
        if r.pulled > 0 {
            try? await store?.reloadHeader()
            await refreshFromDisk()
        }
    }

    /// A CloudKit silent push arrived: something changed remotely.
    func remotePushReceived() { Task { await syncNow() } }

    /// The app became active: catch up in case a push was missed.
    func appActivated() { if mirror != nil { Task { await syncNow() } } }

    /// Local files changed (our own writes): push soon, coalesced.
    private func schedulePush() {
        guard mirror != nil else { return }
        pushDebounce?.cancel()
        pushDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let mirror = self.mirror else { return }
            self.syncStatus = .syncing
            _ = try? await mirror.push()
            self.syncStatus = await mirror.status
            self.lastCloudSync = await mirror.lastSync
        }
    }

    func resetCloudState() async {
        await mirror?.reset()
        await syncNow()
    }

    // MARK: - Lock / unlock

    func unlock(passphrase: String, rememberWithBiometrics: Bool) async {
        guard let store, unlockProgress == nil else { return }
        unlockProgress = .checking
        defer { unlockProgress = nil }
        do {
            let vk = try await store.unlock(passphrase: passphrase, progress: reportUnlockProgress())
            var keychainError: String?
            if rememberWithBiometrics, let vaultId {
                do {
                    try keychain.save(vk, vaultId: vaultId)
                    hasBiometricKey = true
                    UserDefaults.standard.set(true, forKey: Prefs.biometricUnlock)
                } catch {
                    keychainError = "Unlocked, but Touch ID could not be enabled: \(error.localizedDescription)"
                }
            }
            await becameUnlocked()
            errorMessage = keychainError
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithBiometrics() async {
        guard let store, let vaultId, unlockProgress == nil else { return }
        do {
            guard let vk = try keychain.load(vaultId: vaultId) else { return } // cancelled or none
            unlockProgress = .checking
            defer { unlockProgress = nil }
            try await store.unlock(vaultKey: vk, progress: reportUnlockProgress())
            await becameUnlocked()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reportUnlockProgress() -> VaultStore.Progress {
        { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.unlockProgress != nil else { return }
                self.unlockProgress = .decrypting(done: done, total: total)
            }
        }
    }

    func disableBiometrics() {
        guard let vaultId else { return }
        try? keychain.remove(vaultId: vaultId)
        hasBiometricKey = false
        UserDefaults.standard.set(false, forKey: Prefs.biometricUnlock)
    }

    // MARK: - Recovery key

    /// Generates (or replaces) the recovery key and returns it for display.
    func createRecoveryKey() async -> String? {
        guard let store else { return nil }
        do {
            let k = try await store.createRecoveryKey()
            hasRecoveryKey = true
            schedulePush()
            return k
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func unlock(recoveryKey: String) async {
        guard let store, unlockProgress == nil else { return }
        unlockProgress = .checking
        defer { unlockProgress = nil }
        do {
            try await store.unlock(recoveryKey: recoveryKey, progress: reportUnlockProgress())
            await becameUnlocked()
            needsPassphraseReset = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// New passphrase without the old one (after a recovery unlock).
    func resetPassphrase(new: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.resetPassphrase(new: new)
            needsPassphraseReset = false
            schedulePush()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func lock() {
        guard phase == .unlocked, let store else { return }
        autoLock.stop()
        Task { await store.lock() }
        projects = []
        items = []
        selectedItemId = nil
        phase = .locked
    }

    private func becameUnlocked() async {
        phase = .unlocked
        errorMessage = nil
        await reload()
        if selectedProjectId == nil { selectedProjectId = projects.first?.id }
        autoLock.touch()
    }

    func userActivity() { autoLock.touch() }

    // MARK: - Folder watching / refresh

    /// Watches the vault folder from the moment it is opened. Locked: only
    /// cloud pushes happen. Unlocked: new revisions are also indexed.
    private func startWatching() {
        stopWatching()
        guard let url = vaultURL else { return }
        let w = FolderWatcher(url: url)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.changes {
                guard let self, !Task.isCancelled else { return }
                await self.refreshFromDisk()
                self.schedulePush()
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel(); watchTask = nil
        watcher?.stop(); watcher = nil
    }

    /// Picks up revisions written by other devices or the CLI.
    func refreshFromDisk() async {
        guard let store, phase == .unlocked else { return }
        do {
            if try await store.refresh() { await reload() }
            lastRefresh = Date()
        } catch {
            errorMessage = "Sync read failed: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        guard let store else { return }
        projects = await store.projects()
        items = await store.allItems()
        if let pid = selectedProjectId, !projects.contains(where: { $0.id == pid }) { selectedProjectId = projects.first?.id }
        if let iid = selectedItemId, !items.contains(where: { $0.id == iid }) { selectedItemId = nil }
    }

    // MARK: - Mutations

    private func perform(_ op: @escaping (VaultStore) async throws -> Void) async {
        guard let store else { return }
        autoLock.touch()
        do {
            try await op(store)
            await reload()
            errorMessage = nil
            schedulePush()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createProject(name: String, tags: [String] = []) async {
        var created: Project?
        await perform { created = try await $0.createProject(name: name, tags: tags) }
        if let created { selectedProjectId = created.id; selectedItemId = nil }
    }

    func renameProject(_ id: UUID, name: String) async { await perform { try await $0.updateProject(id, name: name) } }
    func setProjectTags(_ id: UUID, tags: [String]) async { await perform { try await $0.updateProject(id, tags: tags) } }
    func deleteProject(_ id: UUID) async {
        await perform { try await $0.deleteProject(id) }
        if selectedProjectId == id { selectedProjectId = projects.first?.id }
    }

    @discardableResult
    func createItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String] = []) async -> Item? {
        var created: Item?
        await perform { created = try await $0.createItem(in: projectId, name: name, payload: payload, tags: tags) }
        if let created { selectedProjectId = projectId; selectedItemId = created.id }
        return created
    }

    func updateItem(_ id: UUID, name: String? = nil, tags: [String]? = nil, payload: ItemPayload? = nil, projectId: UUID? = nil) async {
        await perform { try await $0.updateItem(id, name: name, tags: tags, payload: payload, projectId: projectId) }
    }

    func deleteItem(_ id: UUID) async {
        await perform { try await $0.deleteItem(id) }
        if selectedItemId == id { selectedItemId = nil }
    }

    func history(of itemId: UUID) async -> [ItemRevision] {
        await store?.history(of: itemId) ?? []
    }

    func restore(_ rev: ItemRevision) async { await perform { try await $0.restore(rev) } }
    func compact(itemId: UUID) async { await perform { try await $0.compact(itemId: itemId) } }

    func changePassphrase(current: String, new: String) async -> Bool {
        var ok = false
        await perform { try await $0.changePassphrase(current: current, new: new); ok = true }
        return ok
    }

    // MARK: - Import

    /// Imports each URL as an env file into `projectId`. Returns the number imported.
    @discardableResult
    func importFiles(_ urls: [URL], into projectId: UUID) async -> Int {
        var n = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if await createItem(in: projectId, name: url.lastPathComponent, payload: .envFile(text: text)) != nil { n += 1 }
        }
        return n
    }

    /// Finds `.env*` files up to two levels deep, skipping dependency folders.
    nonisolated static func findEnvFiles(in folder: URL) -> [URL] {
        let skip: Set<String> = ["node_modules", ".git", "vendor", "Pods", "build", "dist", ".next", "target", "DerivedData"]
        var out: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            guard depth <= 2, let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
            for u in entries {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if !skip.contains(u.lastPathComponent) { scan(u, depth: depth + 1) }
                } else if u.lastPathComponent.hasPrefix(".env") || u.lastPathComponent.hasSuffix(".env") {
                    out.append(u)
                }
            }
        }
        scan(folder, depth: 0)
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Tools

    var toolContext: ToolContext {
        ToolContext(
            projects: { [weak self] in await MainActor.run { self?.projects ?? [] } },
            items: { [weak self] pid in await MainActor.run { self?.items(in: pid) ?? [] } },
            copyToClipboard: { text, concealed in Task { @MainActor in ClipboardService.shared.copy(text, concealed: concealed) } }
        )
    }
}
