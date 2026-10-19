import SwiftUI
import LocalAuthentication
import VaultCore
import VaultSync
import ToolKit
import EnvKit

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
    /// Set when the vault opens locked or gets locked; the next time EnVault is (or becomes)
    /// the active app, Touch ID is offered once. Never prompts while another app is in front.
    @ObservationIgnored private var touchIDOfferArmed = false
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
    /// Items kept written into project folders on this Mac.
    let fileLinks = FileLinkStore()
    /// Lets the `envault` CLI unlock through this app. False when another EnVault already holds the port.
    private(set) var agentRunning = false
    @ObservationIgnored private var agent: AgentServer?
    /// Requests from the command line and AI agents since launch, newest first (no values).
    private(set) var agentActivity: [AgentActivity] = []
    /// Per AI agent: approved until. Cleared when the vault locks.
    @ObservationIgnored private var agentGrants: [String: Date] = [:]

    struct AgentActivity: Identifiable {
        enum Outcome { case approved, allowed, refused }
        let id = UUID()
        let date = Date()
        /// The AI agent, or nil for a person in Terminal.
        let agent: String?
        let client: String
        let detail: String?
        let purpose: AIAgents.Purpose
        let outcome: Outcome
        var note: String?
    }
    /// A `.env.vault` dropped in, waiting for its DOTENV_KEY.
    var pendingVaultImport: PendingVaultImport?

    struct PendingVaultImport: Identifiable {
        let id = UUID()
        let projectId: UUID
        let fileName: String
        let text: String
        var environments: [String] { EnvImport.vaultEnvironments(text) }
    }

    private static let iCloudVaultKey = "dk.dinhkhanh.envault.iCloudVaultId"

    init() {
        Prefs.registerDefaults()
        autoLock = AutoLock { [weak self] in self?.lock() }
        fileLinks.hooks = .init(
            item: { [weak self] id in self?.items.first { $0.id == id } },
            history: { [weak self] id in await self?.history(of: id) ?? [] },
            save: { [weak self] id, payload in await self?.saveFromLinkedFile(id, payload: payload) ?? false })
    }

    /// Called once at launch, before any window shows: the CLI agent must answer
    /// even when the app was launched hidden by `envault`.
    func bootstrap() {
        startAgent()
        Task { await start() }
    }

    // MARK: - Derived

    func items(in projectId: UUID) -> [Item] { items.filter { $0.projectId == projectId } }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectId } }
    var selectedItem: Item? { items.first { $0.id == selectedItemId } }
    var isInICloudDrive: Bool { syncMode == .folder && (vaultURL.map(SyncLocations.isInsideICloudDrive) ?? false) }

    // MARK: - Startup

    @ObservationIgnored private var started = false

    func start() async {
        // bootstrap() and the window's .task both call this; phase stays .loading across awaits.
        guard phase == .loading, !started else { return }
        started = true
        #if DEBUG
        // Dev/testing: `EnVault -vaultPath <dir> [-passphrase <pw>]` opens or creates a vault directly.
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
            touchIDOfferArmed = true
            offerTouchIDIfAppropriate()
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
        return support.appendingPathComponent("EnVault/Vaults/\(vaultId.uuidString)", isDirectory: true)
    }
    /// Debug-iCloud builds share this container with release builds but sync to
    /// CloudKit Development, so they keep their own record of what was uploaded.
    private static func stateURL(for vaultId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = CloudKitAvailability.isProduction ? vaultId.uuidString : "\(vaultId.uuidString)-development"
        return support.appendingPathComponent("EnVault/SyncState/\(name).json")
    }

    func createVaultInICloud(passphrase: String) async {
        // The vault id is assigned by VaultStore.create, so create in a temp folder and rename.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tmp = support.appendingPathComponent("EnVault/Vaults/new-\(UUID().uuidString)", isDirectory: true)
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
        await listVaults(in: cloud)
    }

    private func listVaults(in transport: CloudVaultTransport) async -> [CloudVaultSummary] {
        do {
            var out: [CloudVaultSummary] = []
            for id in try await transport.listVaults() {
                let header = try await transport.fetchFile(path: VaultHeader.fileName, vaultId: id).flatMap { try? VaultHeader.decode($0) }
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

    // MARK: - Moving over from eVault

    /// Before 0.6 the app was eVault (bundle id dk.dinhkhanh.evault) and kept iCloud
    /// vaults in this container. EnVault only reads it, to copy a vault into its own.
    static let eVaultContainerIdentifier = "iCloud.dk.dinhkhanh.evault"
    @ObservationIgnored private lazy var eVaultCloud: CloudVaultTransport = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeCloud") { return MemoryCloudTransport() }
        #endif
        return CloudKitTransport(containerIdentifier: Self.eVaultContainerIdentifier)
    }()

    /// iCloud vaults eVault left behind that aren't in EnVault's container yet.
    func listEVaultICloudVaults() async -> [CloudVaultSummary] {
        let moved = Set((try? await cloud.listVaults()) ?? [])
        return await listVaults(in: eVaultCloud).filter { !moved.contains($0.id) }
    }

    /// Copies an eVault iCloud vault (ciphertext) into EnVault's container and opens it.
    /// The eVault copy stays as it was.
    func moveVaultFromEVault(_ id: UUID) async {
        let root = Self.localRoot(for: id)
        let importState = FileManager.default.temporaryDirectory.appendingPathComponent("evault-import-\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            syncStatus = .syncing
            try await CloudMirror(vaultId: id, localRoot: root, stateURL: importState, transport: eVaultCloud).pull()
            try? FileManager.default.removeItem(at: importState)
            syncStatus = .idle
            guard await VaultStore.vaultExists(in: LocalFolderStorage(root: root)) else {
                throw VaultError.io("that vault is empty in eVault's iCloud; open eVault on the Mac that made it and let it sync")
            }
            await openVault(at: root, mode: .iCloud)
            try await mirror?.bootstrap()
            await syncNow()
        } catch {
            syncStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
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
    func appActivated() {
        offerTouchIDIfAppropriate()
        if mirror != nil { Task { await syncNow() } }
    }

    /// Prompts Touch ID if the vault is locked, a key is cached, EnVault is frontmost, and
    /// this lock hasn't been offered yet. Auto-lock in the background therefore waits for
    /// the user to come back; a manual lock doesn't re-prompt until they leave and return.
    func offerTouchIDIfAppropriate() {
        guard touchIDOfferArmed, NSApp.isActive, phase == .locked, hasBiometricKey, unlockProgress == nil else { return }
        touchIDOfferArmed = false
        Task { await unlockWithBiometrics() }
    }

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
            // Off the main actor: the Touch ID sheet blocks the calling thread until answered.
            let keychain = keychain
            guard let vk = try await Task.detached(operation: { try keychain.load(vaultId: vaultId) }).value else {
                // Cancelled, or the item is gone (e.g. fingerprints re-enrolled): offer "Remember" again if so.
                hasBiometricKey = keychain.hasCachedKey(vaultId: vaultId)
                return
            }
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
        if let vaultId { fileLinks.vaultLocked(vaultId: vaultId) }
        autoLock.stop()
        Task { await store.lock() }
        projects = []
        items = []
        // Unlocking starts on the empty "No Project" page, not the last project or tool.
        selectedProjectId = nil
        selectedItemId = nil
        selectedToolId = nil
        phase = .locked
        touchIDOfferArmed = true
        agentGrants = [:]
    }

    private func becameUnlocked() async {
        phase = .unlocked
        touchIDOfferArmed = false
        errorMessage = nil
        await reload()
        if let vaultId { fileLinks.vaultUnlocked(vaultId: vaultId) }
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
        if phase == .unlocked, let vaultId { fileLinks.syncAll(vaultId: vaultId) }
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

    /// An edit made in a linked file (see `FileLinkStore`), saved as a new revision.
    func saveFromLinkedFile(_ id: UUID, payload: ItemPayload) async -> Bool {
        var ok = false
        await perform { try await $0.updateItem(id, payload: payload); ok = true }
        return ok
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

    /// Imports each URL as an env file into `projectId`: dotenv as is, JSON
    /// (Doppler, 1Password item, flat objects) converted, `.env.vault` after
    /// asking for its DOTENV_KEY. Returns the number imported.
    @discardableResult
    func importFiles(_ urls: [URL], into projectId: UUID) async -> Int {
        var n = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            switch EnvImport.detect(text: raw, fileName: name) {
            case .dotenv:
                if await upsertEnvItem(in: projectId, name: name, text: raw) { n += 1 }
            case .json:
                do {
                    let text = try EnvImport.dotenv(fromJSON: raw)
                    if await upsertEnvItem(in: projectId, name: url.deletingPathExtension().lastPathComponent + ".env", text: text) { n += 1 }
                } catch {
                    errorMessage = "\(name): \(error.localizedDescription)"
                }
            case .dotenvVault:
                pendingVaultImport = PendingVaultImport(projectId: projectId, fileName: name, text: raw)
            }
        }
        return n
    }

    /// Decrypts the pending `.env.vault` with one DOTENV_KEY per environment
    /// (newline or comma separated) into `.env.<environment>` items.
    func completeVaultImport(keys: String) async -> String? {
        guard let pending = pendingVaultImport else { return nil }
        let parts = keys.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Paste at least one DOTENV_KEY." }
        do {
            for part in parts {
                let key = try EnvImport.parseDotenvKey(part)
                let text = try EnvImport.decryptVault(pending.text, key: key)
                _ = await upsertEnvItem(in: pending.projectId, name: ".env.\(key.environment)", text: text)
            }
            pendingVaultImport = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Creates the item, or updates it when one with that name already exists and differs.
    @discardableResult
    func upsertEnvItem(in projectId: UUID, name: String, text: String) async -> Bool {
        if let existing = items(in: projectId).first(where: { $0.name == name }) {
            guard existing.payload.primaryText != text else { return false }
            await updateItem(existing.id, payload: .envFile(text: text))
            return true
        }
        return await createItem(in: projectId, name: name, payload: .envFile(text: text)) != nil
    }

    /// Imports projects found by `EnvDiscovery` under `root`; projects that
    /// already exist (same name) get the files merged in.
    func importDiscovered(_ found: [EnvDiscovery.FoundProject], root: URL) async -> (projects: Int, files: Int) {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        var p = 0, f = 0
        for proj in found {
            var pid = projects.first { $0.name == proj.name }?.id
            if pid == nil {
                await createProject(name: proj.name)
                pid = projects.first { $0.name == proj.name }?.id
                if pid != nil { p += 1 }
            }
            guard let pid else { continue }
            for file in proj.files {
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                if await upsertEnvItem(in: pid, name: file.itemName, text: text) { f += 1 }
            }
        }
        selectedProjectId = projects.first { $0.name == found.first?.name }?.id ?? selectedProjectId
        return (p, f)
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

    // MARK: - CLI agent

    private func startAgent() {
        let server = AgentServer(
            info: { [weak self] in
                Agent.Info(vaultId: self?.vaultId, vaultPath: self?.vaultURL?.path(percentEncoded: false),
                           mode: self?.syncMode == .iCloud ? "icloud" : "folder", locked: self?.phase != .unlocked,
                           appVersion: Bundle.main.shortVersion, cliPath: CLIService.bundledCLI.path, agents: Prefs.agentPolicy)
            },
            authorize: { [weak self] request in
                guard let self else { throw Agent.Failure("EnVault is quitting") }
                return try await self.authorizeCLI(request)
            },
            storage: { [weak self] agent in
                guard let self else { throw Agent.Failure("EnVault is quitting") }
                return try self.vaultStorageForCLI(agent: agent)
            })
        agentRunning = server.start()
        agent = server
    }

    /// Hands the vault key to the `envault` CLI after the user approves with
    /// Touch ID (or the login password when the app is unlocked). AI agents
    /// are held to Settings › AI Agents, and one approval can cover their
    /// next commands for a few minutes, except reading values when set to ask.
    private func authorizeCLI(_ r: Agent.KeyRequest) async throws -> VaultKey {
        let isAgent = r.agent != nil
        func refuse(_ message: String, denied: Bool = true) -> Agent.Failure {
            log(r, .refused, note: message)
            return Agent.Failure(message, denied: denied)
        }
        guard UserDefaults.standard.bool(forKey: Prefs.cliAgentEnabled) else {
            throw refuse("unlocking the CLI through the app is turned off in EnVault Settings › Command Line", denied: isAgent)
        }
        // Launched by the CLI a moment ago: let the vault finish opening.
        for _ in 0..<50 where phase == .loading { try? await Task.sleep(for: .milliseconds(200)) }
        guard let store, let vaultId else { throw refuse("no vault is open in EnVault", denied: false) }
        guard r.vaultId == vaultId else { throw refuse("EnVault has a different vault open; pass --vault for this one", denied: false) }

        var policy = Prefs.agentPolicy
        if let agent = r.agent {
            guard policy.enabled else { throw refuse("AI agents are turned off in EnVault Settings › AI Agents") }
            if r.purpose == .reveal, policy.values == .never {
                throw refuse("EnVault doesn't show secret values to AI agents (Settings › AI Agents); use `envault run` instead")
            }
            if r.purpose == .write, !policy.writes {
                throw refuse("AI agents may not change env files (Settings › AI Agents)")
            }
            let mustAsk = r.purpose == .reveal && policy.values == .ask
            if !mustAsk, phase == .unlocked, let until = agentGrants[agent], until > Date(), let key = await store.currentVaultKey() {
                log(r, .allowed)
                return key
            }
        } else {
            policy.approvalMinutes = 0
        }

        let reason = Self.approvalReason(r)
        let key: VaultKey
        if phase == .unlocked, let k = await store.currentVaultKey() {
            let ctx = LAContext()
            do {
                try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                throw refuse("not approved", denied: isAgent)
            }
            key = k
        } else if hasBiometricKey {
            let keychain = keychain
            guard let k = try? await Task.detached(operation: { try keychain.load(vaultId: vaultId, reason: reason) }).value else {
                throw refuse("not approved", denied: isAgent)
            }
            key = k
        } else {
            throw refuse("EnVault is locked and Touch ID unlock is off; unlock the app first", denied: false)
        }
        if let agent = r.agent, policy.approvalMinutes > 0 {
            agentGrants[agent] = Date().addingTimeInterval(TimeInterval(policy.approvalMinutes * 60))
        }
        log(r, .approved)
        return key
    }

    /// The open vault's files for the CLI, which can't read this app's
    /// container itself in iCloud mode. Ciphertext; the key is a separate request.
    private func vaultStorageForCLI(agent: String?) throws -> any VaultStorage {
        guard UserDefaults.standard.bool(forKey: Prefs.cliAgentEnabled) else {
            throw Agent.Failure("the command line is turned off in EnVault Settings › Command Line", denied: true)
        }
        if agent != nil, !Prefs.agentPolicy.enabled {
            throw Agent.Failure("AI agents are turned off in EnVault Settings › AI Agents", denied: true)
        }
        guard store != nil, let vaultURL else { throw Agent.Failure("no vault is open in EnVault") }
        return LocalFolderStorage(root: vaultURL)
    }

    /// Completes "EnVault is trying to …" in the Touch ID prompt.
    private static func approvalReason(_ r: Agent.KeyRequest) -> String {
        let what = r.detail.map { "“\($0)”" } ?? "your vault"
        guard let agent = r.agent else { return "allow “\(r.client)” in Terminal to unlock your vault" }
        switch r.purpose {
        case .use: return "let \(agent) use \(what) (\(r.client))"
        case .write: return "let \(agent) change \(what) (\(r.client))"
        case .reveal: return "show \(agent) the secret values in \(what) (\(r.client))"
        }
    }

    private func log(_ r: Agent.KeyRequest, _ outcome: AgentActivity.Outcome, note: String? = nil) {
        agentActivity.insert(AgentActivity(agent: r.agent, client: r.client, detail: r.detail, purpose: r.purpose, outcome: outcome, note: note), at: 0)
        if agentActivity.count > 100 { agentActivity.removeLast(agentActivity.count - 100) }
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
