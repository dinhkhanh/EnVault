import SwiftUI
import CloudKit
import LocalAuthentication
import LicenseKit
import VaultCore
import VaultSync
import ToolKit
import EnvKit

/// Single source of truth for the UI. Each open vault is a `VaultSession`
/// (store, files, sync, snapshots). The first is the personal vault, which
/// files. Team vaults it remembers are attached while it is unlocked and
/// dropped on lock. The sidebar's switcher picks which vault's projects and
/// items the window shows and edits.
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
    /// Open vaults, the personal vault first.
    private(set) var sessions: [VaultSession] = []
    /// The vault the window shows; nil = the personal vault.
    var selectedVaultId: UUID? {
        didSet {
            guard selectedVaultId != oldValue else { return }
            selectedProjectId = nil
            selectedItemId = nil
            selectedToolId = nil
        }
    }
    var personal: VaultSession? { sessions.first }
    /// The vault whose projects and items the window shows and edits.
    var session: VaultSession? { sessions.first { $0.vaultId == selectedVaultId } ?? personal }
    /// Progress of a download that runs before its session exists (opening or moving an iCloud vault).
    private(set) var downloadStatus: SyncStatus?
    var errorMessage: String?

    // The personal vault's location and sync state (Settings, the Vault menu, the CLI agent).
    var syncMode: SyncMode { personal?.mode ?? .folder }
    var vaultURL: URL? { personal?.url }
    var vaultId: UUID? { personal?.vaultId }
    var syncStatus: SyncStatus { downloadStatus ?? personal?.syncStatus ?? .idle }
    var lastCloudSync: Date? { personal?.lastCloudSync }
    var lastRefresh: Date? { personal?.lastRefresh }
    // The selected vault's content.
    var projects: [Project] { session?.projects ?? [] }
    /// What the Free plan's project limit counts: team vaults are free to use (FR-26).
    var projectsTowardLimit: Int { session?.isTeam == true ? 0 : projects.count }
    var items: [Item] { session?.items ?? [] }
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

    /// The personal vault's store: unlocking, recovery, passphrase, identity, CLI.
    private var store: VaultStore? { personal?.personalStore }
    private var mirror: CloudMirror? { personal?.mirror }
    @ObservationIgnored private var autoLock: AutoLock!
    @ObservationIgnored private let keychain = KeychainVaultKeyStore()
    @ObservationIgnored private lazy var cloud: CloudVaultTransport = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeCloud") { return MemoryCloudTransport() }
        #endif
        return CloudKitTransport()
    }()
    /// Zone-wide sharing of team vaults; nil without CloudKit (and with the debug fake cloud).
    @ObservationIgnored private lazy var sharing: CloudKitSharing? = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeCloud") { return nil }
        #endif
        return cloudAvailable ? CloudKitSharing() : nil
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
        ShareInbox.shared.handler = { [weak self] m in Task { await self?.acceptShare(m) } }
        autoLock = AutoLock { [weak self] in self?.lock() }
        fileLinks.hooks = .init(
            // Linked files belong to the personal vault, whichever vault the window shows.
            item: { [weak self] id in self?.personal?.items.first { $0.id == id } },
            history: { [weak self] id in await self?.personal?.store.history(of: id) ?? [] },
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
            let s = try await VaultStore.open(storage: LocalFolderStorage(root: url))
            let id = await s.vaultId
            if mode == .folder { try VaultLocation.save(url) } else { UserDefaults.standard.set(id.uuidString, forKey: Self.iCloudVaultKey) }
            begin(VaultSession(store: s, url: url, vaultId: id, mode: mode, name: "Personal"))
            hasBiometricKey = keychain.hasCachedKey(vaultId: id)
            hasRecoveryKey = await s.hasRecoveryKey
            phase = .locked
            errorMessage = nil
            touchIDOfferArmed = true
            offerTouchIDIfAppropriate()
        } catch {
            errorMessage = error.localizedDescription
            if phase == .loading { phase = .noVault }
        }
    }

    func createVault(at url: URL, passphrase: String, mode: SyncMode) async {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let s = try await VaultStore.create(storage: LocalFolderStorage(root: url), passphrase: passphrase)
            let id = await s.vaultId
            if mode == .folder { try VaultLocation.save(url) } else { UserDefaults.standard.set(id.uuidString, forKey: Self.iCloudVaultKey) }
            begin(VaultSession(store: s, url: url, vaultId: id, mode: mode, name: "Personal"))
            hasBiometricKey = false
            errorMessage = nil
            pendingRecoveryKey = try await s.createRecoveryKey()
            hasRecoveryKey = true
            if mode == .iCloud { try await mirror?.bootstrap() }
            await becameUnlocked()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forget the current vault (does not delete any files).
    func closeVault() {
        lock()
        for s in sessions { s.close() }
        sessions = []
        selectedVaultId = nil
        unlocatedTeams = []
        VaultLocation.forget()
        UserDefaults.standard.removeObject(forKey: Self.iCloudVaultKey)
        phase = .noVault
    }

    /// Makes `new` the personal vault: replaces every open session, starts
    /// watching its folder and, in iCloud mode, syncing it.
    private func begin(_ new: VaultSession) {
        for s in sessions { s.close() }
        wire(new)
        sessions = [new]
        selectedVaultId = nil
        downloadStatus = nil
        new.startWatching()
        if new.mode == .iCloud, cloudAvailable {
            new.startCloud(transport: cloud, stateURL: Self.stateURL(for: new.vaultId))
        }
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
                downloadStatus = .syncing
                try await m.pull()
                downloadStatus = nil
            }
            await openVault(at: root, mode: .iCloud)
        } catch {
            downloadStatus = .error(error.localizedDescription)
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
            downloadStatus = .syncing
            try await CloudMirror(vaultId: id, localRoot: root, stateURL: importState, transport: eVaultCloud).pull()
            try? FileManager.default.removeItem(at: importState)
            downloadStatus = nil
            guard await VaultStore.vaultExists(in: LocalFolderStorage(root: root)) else {
                throw VaultError.io("that vault is empty in eVault's iCloud; open eVault on the Mac that made it and let it sync")
            }
            await openVault(at: root, mode: .iCloud)
            try await mirror?.bootstrap()
            await syncNow()
        } catch {
            downloadStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func wire(_ s: VaultSession) {
        s.didReload = { [weak self, weak s] in if let s { self?.sessionDidReload(s) } }
        s.reportError = { [weak self] in self?.errorMessage = $0 }
    }

    /// Full pull + push of every open vault. Safe to call any time, locked or
    /// not. Clears a failed download's status, as the vault's own sync now speaks.
    func syncNow() async {
        guard !sessions.isEmpty else { return }
        downloadStatus = nil
        for s in sessions { await s.syncNow() }
    }

    /// A CloudKit silent push arrived: something changed remotely.
    func remotePushReceived() { Task { await syncNow() } }

    /// The app became active: catch up in case a push was missed.
    func appActivated() {
        offerTouchIDIfAppropriate()
        if sessions.contains(where: { $0.mirror != nil }) { Task { await syncNow() } }
    }

    /// Prompts Touch ID if the vault is locked, a key is cached, EnVault is frontmost, and
    /// this lock hasn't been offered yet. Auto-lock in the background therefore waits for
    /// the user to come back; a manual lock doesn't re-prompt until they leave and return.
    func offerTouchIDIfAppropriate() {
        guard touchIDOfferArmed, NSApp.isActive, phase == .locked, hasBiometricKey, unlockProgress == nil else { return }
        touchIDOfferArmed = false
        Task { await unlockWithBiometrics() }
    }

    func resetCloudState() async { await personal?.resetCloudState() }

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
            personal?.schedulePush()
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
            personal?.schedulePush()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func lock() {
        guard phase == .unlocked, let personal else { return }
        fileLinks.vaultLocked(vaultId: personal.vaultId)
        autoLock.stop()
        // Attached vaults go away entirely; they come back with the next unlock.
        for s in sessions.dropFirst() {
            s.close()
            Task { await s.store.lock() }
        }
        sessions = [personal]
        selectedVaultId = nil
        unlockGeneration += 1
        unlocatedTeams = []
        TeamFolders.stopAll()
        Task { await personal.store.lock() }
        personal.isUnlocked = false
        personal.clear()
        identity = nil
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
        personal?.isUnlocked = true
        touchIDOfferArmed = false
        errorMessage = nil
        await reload()
        if let vaultId { fileLinks.vaultUnlocked(vaultId: vaultId) }
        autoLock.touch()
        await loadIdentity()
        await openTeams()
        if let share = ShareInbox.shared.take() { await acceptShare(share) }
    }

    func userActivity() { autoLock.touch() }

    // MARK: - Refresh

    /// Picks up revisions written by other devices or the CLI, in every open vault.
    func refreshFromDisk() async {
        for s in sessions { await s.refreshFromDisk() }
    }

    private func reload() async { await session?.reload() }

    /// A vault's snapshots changed: keep the selection valid if it is the one
    /// shown, and keep linked files current (personal vault only for now).
    private func sessionDidReload(_ s: VaultSession) {
        if s === session {
            if let pid = selectedProjectId, !projects.contains(where: { $0.id == pid }) { selectedProjectId = projects.first?.id }
            if let iid = selectedItemId, !items.contains(where: { $0.id == iid }) { selectedItemId = nil }
        }
        if phase == .unlocked, s === personal { fileLinks.syncAll(vaultId: s.vaultId) }
        if s.isTeam { teamDidReload(s) }
    }

    #if DEBUG
    /// Debug only until team vaults exist (phase 2): opens another folder vault
    /// next to the personal one, unlocked with its own passphrase, to exercise
    /// the switcher. Dropped on lock like every attached vault.
    func attachVault(at url: URL, passphrase: String) async {
        guard phase == .unlocked else { return }
        errorMessage = nil
        do {
            let s = try await VaultStore.open(storage: LocalFolderStorage(root: url))
            let id = await s.vaultId
            if sessions.contains(where: { $0.vaultId == id }) { selectedVaultId = id; return }
            try await s.unlock(passphrase: passphrase)
            let new = VaultSession(store: s as any VaultContent, url: url, vaultId: id, mode: .folder, name: url.lastPathComponent)
            wire(new)
            new.isUnlocked = true
            sessions.append(new)
            new.startWatching()
            await new.reload()
            selectedVaultId = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    // MARK: - Mutations

    /// Runs a change on `target` (default: the vault shown), then refreshes and pushes it.
    private func perform(on target: VaultSession? = nil, content: Bool = true, _ op: @escaping (any VaultContent) async throws -> Void) async {
        guard let s = target ?? session else { return }
        autoLock.touch()
        do {
            if content { try checkWritable(s) }
            try await op(s.store)
            await s.reload()
            errorMessage = nil
            s.schedulePush()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Team identity (FR-1, FR-2)

    /// What views may show of the identity; the private keys stay in the store.
    struct IdentitySummary: Equatable, Sendable {
        var name: String
        var safetyCode: String
    }
    private(set) var identity: IdentitySummary?

    func loadIdentity() async {
        let current = (try? await store?.identity()) ?? nil
        identity = current.map { IdentitySummary(name: $0.name, safetyCode: $0.safetyCode) }
    }

    func createIdentity(name: String) async {
        await performOnPersonal { try await $0.createIdentity(name: name) }
        await loadIdentity()
    }

    func renameIdentity(_ name: String) async {
        await performOnPersonal { try await $0.renameIdentity(name) }
        await loadIdentity()
    }

    /// A change only the personal vault supports (identity, passphrase, team records).
    private func performOnPersonal(_ op: @escaping (VaultStore) async throws -> Void) async {
        await perform(on: personal) { content in
            guard let s = content as? VaultStore else { return }
            try await op(s)
        }
    }

    func createProject(name: String, tags: [String] = []) async {
        var created: Project?
        await perform { created = try await $0.createProject(name: name, tags: tags) }
        if let created { selectedProjectId = created.id; selectedItemId = nil }
    }

    func renameProject(_ id: UUID, name: String) async { await perform { try await $0.updateProject(id, name: name, tags: nil) } }
    func setProjectTags(_ id: UUID, tags: [String]) async { await perform { try await $0.updateProject(id, name: nil, tags: tags) } }
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
        await perform(on: personal) { try await $0.updateItem(id, name: nil, tags: nil, payload: payload, projectId: nil); ok = true }
        return ok
    }

    func deleteItem(_ id: UUID) async {
        await perform { try await $0.deleteItem(id) }
        if selectedItemId == id { selectedItemId = nil }
    }

    func history(of itemId: UUID) async -> [ItemRevision] {
        await session?.store.history(of: itemId) ?? []
    }

    func restore(_ rev: ItemRevision) async { await perform { try await $0.restore(rev) } }
    /// Personal vaults only: in a team vault, compaction needs every member's Mac to have synced (NFR-11).
    func compact(itemId: UUID) async {
        await perform {
            guard let s = $0 as? VaultStore else { throw VaultError.notPermitted("Team vaults keep every revision for now.") }
            try await s.compact(itemId: itemId)
        }
    }

    func changePassphrase(current: String, new: String) async -> Bool {
        var ok = false
        await performOnPersonal { try await $0.changePassphrase(current: current, new: new); ok = true }
        return ok
    }

    // MARK: - Team vaults (FR-3 to FR-12)

    /// Whether this build can host and join team vaults (CloudKit).
    var teamVaultsAvailable: Bool { TeamFeatures.enabled && sharing != nil }
    /// Set when a share link needs a Team identity first; the UI asks for a name.
    var shareNeedsIdentity = false

    private static func seenURL(for vaultId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(TeamSeen.fileName(vaultId: vaultId))
    }

    private func transport(for record: TeamRecord) -> CloudVaultTransport {
        if let owner = record.zoneOwner, let sharing { return sharing.transport(for: SharedVaultRef(vaultId: record.vaultId, ownerName: owner)) }
        return cloud
    }

    /// Bumped on every lock, so a team vault still opening when the app locks
    /// is dropped instead of attached.
    @ObservationIgnored private var unlockGeneration = 0
    /// Team vaults being opened right now (a share link can arrive during `openTeams`).
    @ObservationIgnored private var opening: Set<UUID> = []
    /// Per team vault (owner's Mac): members who are no longer on the iCloud share.
    private(set) var offShare: [UUID: Set<UUID>] = [:]
    /// Folder-mode team vaults this person belongs to whose folder this Mac doesn't know yet.
    private(set) var unlocatedTeams: [TeamRecord] = []

    /// Where a team vault's files are on this Mac: the app's container for
    /// iCloud teams, the folder the person chose for folder teams.
    private func teamRoot(_ record: TeamRecord) -> URL? {
        if record.kind == TeamRecord.folder {
            return sessions.first { $0.vaultId == record.vaultId }?.url ?? TeamFolders.restore(record.vaultId)
        }
        return Self.localRoot(for: record.vaultId)
    }

    /// Opens every team vault the personal vault remembers.
    private func openTeams() async {
        unlocatedTeams = []
        guard TeamFeatures.enabled, let store, let me = try? await store.identity() else { return }
        let generation = unlockGeneration
        // iCloud teams need the CloudKit entitlement; folder teams don't.
        for record in await store.teams() where (record.kind == TeamRecord.cloudKit && cloudAvailable) || record.kind == TeamRecord.folder {
            guard !sessions.contains(where: { $0.vaultId == record.vaultId }), opening.insert(record.vaultId).inserted else { continue }
            defer { opening.remove(record.vaultId) }
            guard let root = teamRoot(record) else {
                unlocatedTeams.append(record)   // folder mode, not yet located on this Mac
                continue
            }
            do {
                if record.kind == TeamRecord.cloudKit {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    if await !VaultStore.vaultExists(in: LocalFolderStorage(root: root)) {
                        try await CloudMirror(vaultId: record.vaultId, localRoot: root, stateURL: Self.stateURL(for: record.vaultId),
                                              transport: transport(for: record)).pull()
                    }
                }
                let team = try await TeamVaultStore.open(storage: LocalFolderStorage(root: root), owner: record.ownerKey)
                guard team.vaultId == record.vaultId else { throw VaultError.corruptHeader("the folder holds a different team vault") }
                try await team.unlock(identity: me, seen: VaultSession.seen(at: Self.seenURL(for: record.vaultId)))
                await attach(team, record: record, generation: generation)
            } catch {
                errorMessage = "A team vault didn't open: \(error.localizedDescription)"
            }
        }
    }

    /// Adds an unlocked team vault as a session, watching and syncing it.
    /// Nil (and the store locked again) when the app locked meanwhile or the
    /// vault is already open.
    @discardableResult
    private func attach(_ team: TeamVaultStore, record: TeamRecord, generation: Int) async -> VaultSession? {
        let title = await team.title
        guard phase == .unlocked, generation == unlockGeneration, !sessions.contains(where: { $0.vaultId == record.vaultId }) else {
            await team.lock()
            return nil
        }
        guard let root = teamRoot(record), team.vaultId == record.vaultId else { await team.lock(); return nil }
        let isCloud = record.kind == TeamRecord.cloudKit
        let s = VaultSession(store: team, url: root, vaultId: record.vaultId, mode: isCloud ? .iCloud : .folder, name: title ?? "Team vault")
        s.seenURL = Self.seenURL(for: record.vaultId)
        s.hostsShare = isCloud && record.zoneOwner == nil
        s.didSyncTeam = { [weak self] in await self?.reconcileShare($0) }
        wire(s)
        s.isUnlocked = true
        sessions.append(s)
        unlocatedTeams.removeAll { $0.vaultId == record.vaultId }
        await s.reload()
        s.startWatching()
        await syncLicense(s)
        if isCloud {
            // Upkeep runs after its first sync, so it never acts on a stale copy.
            s.startCloud(transport: transport(for: record), stateURL: Self.stateURL(for: record.vaultId))
        } else {
            await s.upkeep()
        }
        return s
    }

    /// Creates a team vault owned by this person (FR-3): in their iCloud, or
    /// in `folder` (an empty shared folder: Dropbox, a git checkout…). The
    /// caller has checked the Team license and made sure an identity exists.
    func createTeamVault(title: String, folder: URL? = nil) async -> Bool {
        guard phase == .unlocked, let store, folder != nil || cloudAvailable else {
            errorMessage = "Choose a shared folder: iCloud isn't available in this build."
            return false
        }
        let generation = unlockGeneration
        do {
            guard let me = try await store.identity() else { throw VaultError.notPermitted("Set up your Team identity first.") }
            let id = UUID()
            let root = folder ?? Self.localRoot(for: id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let team = try await TeamVaultStore.create(storage: LocalFolderStorage(root: root), owner: me, title: title, vaultId: id)
            let record = TeamRecord(vaultId: id, ownerKey: team.header.owner.signingKey, kind: folder == nil ? TeamRecord.cloudKit : TeamRecord.folder)
            if let folder { try TeamFolders.save(folder, for: id) }
            try await store.saveTeam(record)
            personal?.schedulePush()
            errorMessage = nil
            // The vault exists from here on; iCloud catches up on the next sync if it is unreachable now.
            guard let s = await attach(team, record: record, generation: generation) else { return true }
            try? await s.mirror?.bootstrap()
            selectedVaultId = id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Invites someone by their Apple ID's email (FR-6) and returns the share
    /// link to send them. They join as a pending member until an admin
    /// approves. Everyone joins able to write, so their join request can
    /// upload; the owner's Mac makes a viewer read-only once approved.
    func invite(email: String, role: TeamRole = .member, to s: VaultSession) async -> URL? {
        guard let sharing, s.isTeam else { errorMessage = "Invites need iCloud (CloudKit)."; return nil }
        guard s.hostsShare else {
            errorMessage = "Only the Mac of the person who created this vault can invite people for now."
            return nil
        }
        do {
            try await sharing.shareVault(s.vaultId, title: s.name)
            // FR-6: the same signed invitation folder teams use, with the role and its 7 days.
            // The participant is matched to it by email, on this Mac only (names stay out of the log).
            if let t = s.teamStore {
                let invite = try await t.createInvite(role: role)
                var map = Self.cloudInvites(s.vaultId)
                map[email.lowercased()] = invite.invite.string
                UserDefaults.standard.set(map, forKey: Self.cloudInvitesKey(s.vaultId))
            }
            let url = try await sharing.addParticipant(email: email, canWrite: true, to: s.vaultId).url
            await s.reload()
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A share link was opened (FR-7): accept it, download the vault, remember
    /// it with its owner's key, and ask to join. Waits for the unlock, and for a
    /// Team identity, when either is missing.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        guard TeamFeatures.enabled else { return }
        guard phase == .unlocked, let store else {
            ShareInbox.shared.hold(metadata)
            errorMessage = "Unlock EnVault to open the vault shared with you."
            return
        }
        guard let sharing else { errorMessage = "Shared vaults need iCloud (CloudKit)."; return }
        let generation = unlockGeneration
        var openingId: UUID?
        defer { if let openingId { opening.remove(openingId) } }
        do {
            guard let me = try await store.identity() else {
                ShareInbox.shared.hold(metadata)
                shareNeedsIdentity = true
                return
            }
            shareNeedsIdentity = false
            let ref = try await sharing.accept(metadata)
            if sessions.contains(where: { $0.vaultId == ref.vaultId }) { selectedVaultId = ref.vaultId; return }
            guard opening.insert(ref.vaultId).inserted else { return }
            openingId = ref.vaultId
            var record = TeamRecord(vaultId: ref.vaultId, ownerKey: Data(), zoneOwner: ref.ownerName)
            let root = Self.localRoot(for: ref.vaultId)
            // This person may have seen the vault before, on any Mac (also before leaving it): same owner only.
            let pinned = await store.pinnedOwnerKey(for: ref.vaultId)
            // Never opened: download afresh, not on top of what a refused attempt left behind.
            if pinned == nil {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: Self.stateURL(for: ref.vaultId))
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            downloadStatus = .syncing
            defer { downloadStatus = nil }
            let download = CloudMirror(vaultId: ref.vaultId, localRoot: root, stateURL: Self.stateURL(for: ref.vaultId), transport: transport(for: record))
            try await download.pull()
            // First sight: the header must be the one the zone's owner uploaded and nobody
            // changed since, or a participant could have swapped in their own just before.
            if pinned == nil, await download.creator(of: VaultHeader.fileName) != ref.ownerName {
                throw VaultError.corruptHeader("the vault's header wasn't written by the person who shared it")
            }
            let team = try await TeamVaultStore.open(storage: LocalFolderStorage(root: root), owner: pinned)
            record.ownerKey = team.header.owner.signingKey
            try await store.saveTeam(record)
            personal?.schedulePush()
            let access = try await team.unlock(identity: me, seen: VaultSession.seen(at: Self.seenURL(for: ref.vaultId)))
            if access == .notMember || access == .removed, await !team.hasRequestedToJoin {
                try await team.requestToJoin()
            }
            guard let s = await attach(team, record: record, generation: generation) else { return }
            // Subscribes to the shared database's pushes (one subscription covers every shared vault).
            try? await s.mirror?.bootstrap()
            s.schedulePush()
            selectedVaultId = ref.vaultId
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open the shared vault: \(error.localizedDescription)"
        }
    }

    // MARK: Folder-mode teams (FR-6)

    /// Creates an invitation file's contents for a folder-mode team vault.
    func createInvite(role: TeamRole, in s: VaultSession) async -> TeamInvite? {
        guard let t = s.teamStore else { return nil }
        do {
            let invite = try await t.createInvite(role: role)
            await s.reload()
            return invite
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Joins a folder-mode team vault from an invitation file: checks the
    /// shared folder against the owner key the file carries, remembers the
    /// folder on this Mac, and asks to join.
    func join(_ invite: TeamInvite, folder: URL) async {
        guard TeamFeatures.enabled, phase == .unlocked, let store else { return }
        let generation = unlockGeneration
        do {
            guard let me = try await store.identity() else {
                shareNeedsIdentity = true
                errorMessage = "Create your Team identity first (Settings › Vault), then open the invitation again."
                return
            }
            if sessions.contains(where: { $0.vaultId == invite.vaultId }) { selectedVaultId = invite.vaultId; return }
            if let pinned = await store.pinnedOwnerKey(for: invite.vaultId), pinned != invite.ownerKey {
                throw VaultError.corruptHeader("this invitation names a different owner than the one you knew for this vault")
            }
            let team = try await TeamVaultStore.open(storage: LocalFolderStorage(root: folder), owner: invite.ownerKey)
            guard team.vaultId == invite.vaultId else {
                throw VaultError.corruptHeader("this folder holds a different team vault from the one in the invitation")
            }
            // This Mac may have seen the vault before (a folder it couldn't locate): keep that history.
            let access = try await team.unlock(identity: me, seen: VaultSession.seen(at: Self.seenURL(for: invite.vaultId)))
            if access == .notMember || access == .removed {
                try invite.check(header: team.header, state: await team.state)
                if await !team.hasRequestedToJoin { try await team.requestToJoin(invite: invite.invite) }
            }
            try TeamFolders.save(folder, for: invite.vaultId)
            let record = TeamRecord(vaultId: invite.vaultId, ownerKey: invite.ownerKey, kind: TeamRecord.folder)
            try await store.saveTeam(record)
            personal?.schedulePush()
            guard await attach(team, record: record, generation: generation) != nil else { return }
            selectedVaultId = invite.vaultId
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't join: \(error.localizedDescription)"
        }
    }

    /// Tells this Mac where a folder-mode team vault it already belongs to is.
    func locate(_ record: TeamRecord, folder: URL) async {
        guard let store, let me = try? await store.identity() else { return }
        let generation = unlockGeneration
        do {
            let team = try await TeamVaultStore.open(storage: LocalFolderStorage(root: folder), owner: record.ownerKey)
            guard team.vaultId == record.vaultId else { throw VaultError.io("That folder holds a different team vault.") }
            try await team.unlock(identity: me, seen: VaultSession.seen(at: Self.seenURL(for: record.vaultId)))
            try TeamFolders.save(folder, for: record.vaultId)
            guard await attach(team, record: record, generation: generation) != nil else { return }
            selectedVaultId = record.vaultId
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Approves a join request after the safety code was compared (FR-8, FR-9).
    func approve(_ pending: PendingMember, name: String, role: TeamRole, in s: VaultSession) async {
        // FR-10: the Team license's seats cover every active member, viewers included.
        let license = teamLicense(of: s)
        guard let seats = license.seats else {
            errorMessage = license == .missing
                ? "This vault has no Team license yet. It arrives when the owner's Mac, with a Team license, syncs."
                : "The Team license doesn't allow new members: \(Self.describe(license))"
            return
        }
        guard seatsUsed(in: s) < seats else {
            errorMessage = "The Team license covers \(seats) seats and all are taken. The owner can add seats in their subscription."
            return
        }
        await performOnTeam(s) { try await $0.add(pending.identity, name: name, role: role) }
        await reconcileShare(s)
    }

    // MARK: Team license (FR-10, FR-25, FR-27, FR-28)

    @ObservationIgnored private let licenseVerifier = try? LicenseVerifier(publicKeyBase64: LicensePublicKey.base64, revoked: RevokedLicenses.ids)

    /// This Mac's own license key (from Settings › License). The owner's Mac
    /// puts a Team key into each vault it owns, so renewals reach the team.
    var ownLicenseKey: String? {
        didSet { if ownLicenseKey != oldValue { Task { for s in sessions where s.isTeam { await syncLicense(s) } } } }
    }

    func teamLicense(of s: VaultSession) -> TeamLicenseStatus {
        guard let licenseVerifier else { return .invalid("License checks aren't set up in this build.") }
        // A license event this Mac has seen can't disappear or roll back: someone
        // with access to the files removed it, perhaps to lift read-only.
        if let seen = Self.seenLicenseEvent(s.vaultId), (s.team?.licenseEvent).map({ $0 < seen }) ?? true {
            return .invalid("The vault's license was removed or rolled back. The owner's Mac puts it back when it next opens the vault.")
        }
        return TeamLicenseStatus.evaluate(s.team?.license?.entitlement, verifier: licenseVerifier)
    }

    /// Seats in use for a team vault's license: its members plus the people in
    /// the owner's other team vaults (each person counted once).
    func seatsUsed(in s: VaultSession) -> Int {
        (s.team?.members.count ?? 0) + (s.team?.license?.elsewhere ?? 0)
    }

    /// On the owner's Mac: people in the owner's other team vaults who aren't in `s`.
    private func peopleElsewhere(than s: VaultSession) -> Int {
        let here = Set(s.team?.members.map(\.id) ?? [])
        var others = Set<UUID>()
        for o in sessions where o !== s && o.isTeam && o.team?.role == .owner {
            others.formUnion(o.team?.members.map(\.id) ?? [])
        }
        return others.subtracting(here).count
    }

    private static func seenLicenseKey(_ vaultId: UUID) -> String { "dk.dinhkhanh.envault.teamLicenseEvent.\(vaultId.uuidString)" }
    private static func seenLicenseEvent(_ vaultId: UUID) -> ULID? {
        UserDefaults.standard.string(forKey: seenLicenseKey(vaultId)).flatMap(ULID.init(string:))
    }

    /// Remembers the newest license event, and keeps the owner's key in the vault.
    private func teamDidReload(_ s: VaultSession) {
        if let event = s.team?.licenseEvent, Self.seenLicenseEvent(s.vaultId).map({ event > $0 }) ?? true {
            UserDefaults.standard.set(event.string, forKey: Self.seenLicenseKey(s.vaultId))
        }
        // Any of the owner's vaults changing can change the others' counts.
        if s.team?.role == .owner { Task { for o in sessions where o.isTeam { await syncLicense(o) } } }
    }

    static func describe(_ status: TeamLicenseStatus) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        switch status {
        case .missing: return "no Team license yet"
        case .invalid(let why): return why
        case .active(let seats, let expires): return "\(seats) seats" + (expires.map { ", renews by \($0.formatted(f))" } ?? "")
        case .grace(let seats, let from): return "\(seats) seats; expired, read-only from \(from.formatted(f)) unless renewed"
        case .readOnly(let since): return "expired; read-only since \(since.formatted(f))"
        }
    }

    /// FR-27: no new secrets in a team vault whose license lapsed past the grace period.
    private func checkWritable(_ s: VaultSession) throws {
        guard s.isTeam else { return }
        let license = teamLicense(of: s)
        guard license.allowsWrites else {
            throw VaultError.notPermitted("This team vault is read-only: its Team license \(Self.describe(license)). Nothing is lost; saving works again once the owner renews.")
        }
    }

    /// On the owner's Mac: puts the vault entitlement from this Mac's Team key
    /// into the vault, with the count of people in the owner's other team vaults,
    /// when either changed. Never the key itself: members could reuse it.
    private func syncLicense(_ s: VaultSession) async {
        guard s.team?.role == .owner, let own = ownLicenseKey, let licenseVerifier,
              let mine = try? licenseVerifier.verify(own), mine.plan == .team, let entitlement = mine.vaultEntitlement,
              let fresh = try? licenseVerifier.verify(entitlement), fresh.plan == .teamVault else { return }
        var next = TeamVaultLicense(entitlement: LicenseCodec.normalize(entitlement), elsewhere: peopleElsewhere(than: s))
        if let current = s.team?.license {
            // The newest key wins (a renewal or a seat change replaces the one before),
            // so two of the owner's Macs holding different keys never take turns.
            if let theirs = try? licenseVerifier.verify(current.entitlement, allowExpired: true), theirs.plan == .teamVault,
               theirs.issuedAt > fresh.issuedAt {
                next.entitlement = current.entitlement
            }
            if next == current { return }
        }
        await performOnTeam(s) { try await $0.setLicense(next) }
    }

    func setRole(of member: UUID, to role: TeamRole, in s: VaultSession) async {
        await performOnTeam(s) { try await $0.setRole(of: member, to: role) }
        await reconcileShare(s)
    }

    /// Removes a member and rotates the key (FR-13); the owner's Mac also takes them off the share.
    func remove(_ member: UUID, from s: VaultSession) async {
        await performOnTeam(s) { try await $0.remove(member) }
        await reconcileShare(s)
    }

    func setAgentRules(_ rules: TeamAgentRules, in s: VaultSession) async {
        await performOnTeam(s) { try await $0.setAgentRules(rules) }
    }

    /// Marks a project or item of the vault shown "for people only" (FR-24).
    func setHumansOnly(_ id: UUID, _ on: Bool) async {
        guard let s = session, s.isTeam else { return }
        await performOnTeam(s) { try await $0.setHumansOnly(id, on) }
    }

    /// Hands ownership to an admin (FR-29). Billing moves with a new license (phase 4).
    func transferOwnership(to member: UUID, in s: VaultSession) async {
        await performOnTeam(s) { try await $0.transferOwnership(to: member) }
    }

    /// Exports the vault as a new personal vault in `folder` (FR-30). Returns whether it worked.
    func exportTeamVault(_ s: VaultSession, to folder: URL, passphrase: String) async -> Bool {
        guard let t = s.teamStore else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            try await t.exportAsPersonalVault(to: LocalFolderStorage(root: folder), passphrase: passphrase)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameTeamVault(_ s: VaultSession, to title: String) async {
        await performOnTeam(s) { try await $0.setTitle(title) }
    }

    func dismissLateEvents(in s: VaultSession) async {
        guard let t = s.teamStore, let late = s.team?.lateEvents else { return }
        await t.dismissLate(late)
        await s.reload()
    }

    /// Leaves a team vault (FR-15): signs the removal, leaves the share, and
    /// deletes this Mac's copy and sync state. A signed removal must reach
    /// iCloud first, or the team would still list this person. Viewers can't
    /// upload, so they only leave the share; the owner's Mac then shows them
    /// as off the share, to remove.
    func leave(_ s: VaultSession) async {
        guard let t = s.teamStore, let store else { return }
        do {
            if s.team?.role?.canWrite == true { try await t.leave() }
            // A folder team's removal is in the shared folder already; an iCloud one must reach iCloud first.
            if s.mode == .iCloud, let event = await t.leaveEvent {
                await s.syncNow()
                guard await s.mirror?.isUploaded("members/\(event.string).json") == true else {
                    errorMessage = "You haven't left yet: your Mac couldn't reach iCloud. Try again when it's online."
                    return
                }
            }
            if let record = await store.teams().first(where: { $0.vaultId == s.vaultId }) {
                if let owner = record.zoneOwner, let sharing { try? await sharing.leave(SharedVaultRef(vaultId: s.vaultId, ownerName: owner)) }
                var left = record
                left.left = true
                try await store.saveTeam(left)
                personal?.schedulePush()
            }
            closeTeam(s)
            if s.mode == .iCloud {
                try? FileManager.default.removeItem(at: s.url)
                try? FileManager.default.removeItem(at: Self.stateURL(for: s.vaultId))
            } else {
                // A shared folder belongs to the team: only forget where it is.
                TeamFolders.forget(s.vaultId)
            }
            try? FileManager.default.removeItem(at: Self.seenURL(for: s.vaultId))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeTeam(_ s: VaultSession) {
        s.close()
        if s.mode == .folder { TeamFolders.stop(s.vaultId) }
        Task { await s.store.lock() }
        sessions.removeAll { $0 === s }
        if selectedVaultId == s.vaultId { selectedVaultId = nil }
    }

    /// Copies (or moves) a project with its history into a team vault (FR-5).
    func copyProject(_ projectId: UUID, to target: VaultSession, move: Bool) async {
        guard let source = session, source !== target, let team = target.teamStore else { return }
        do {
            try checkWritable(target)
            let exported = try await source.store.export(projectId)
            try await team.importProject(exported.history, items: exported.items)
            await target.reload()
            target.schedulePush()
            if move {
                await perform(on: source) { try await $0.deleteProject(projectId) }
                if selectedProjectId == projectId { selectedProjectId = nil }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// In a team vault, the keys of an env file whose current value people who
    /// left could read, with their names (FR-14). Empty in a personal vault.
    func exposedKeys(of item: Item) async -> [String: String] {
        guard let s = session, let t = s.teamStore, let team = s.team, team.exposed[item.id] != nil else { return [:] }
        var revisions: [(text: String, readers: Set<UUID>)] = []
        for r in await t.history(of: item.id) {
            guard case .envFile(let text) = r.payload else { continue }
            revisions.append((text, await t.formerReaders(of: r.id)))
        }
        return EnvHygiene.exposedKeys(revisions: revisions).mapValues { ids in
            ids.map(team.name).sorted().formatted(.list(type: .and))
        }
    }

    /// Who wrote each revision, by name, in a team vault (FR-19). Empty in a personal vault.
    func authorNames(of revisions: [ItemRevision]) async -> [ULID: String] {
        guard let s = session, let t = s.teamStore, let team = s.team else { return [:] }
        var out: [ULID: String] = [:]
        for r in revisions { if let a = await t.author(of: r.id) { out[r.id] = team.name(a) } }
        return out
    }

    private func performOnTeam(_ s: VaultSession, _ op: @escaping (TeamVaultStore) async throws -> Void) async {
        // Membership changes stay possible in a read-only vault (removing, leaving, renewing).
        await perform(on: s, content: false) { content in
            guard let t = content as? TeamVaultStore else { return }
            try await op(t)
        }
    }

    /// On the owner's Mac, keeps the CloudKit share in step with the team
    /// (FR-12): every member's participant can write exactly when their role
    /// can, and people removed from the team are taken off the share, which is
    /// what stops them uploading anything more. A participant is matched to a
    /// member by who uploaded the member's join request, as CloudKit recorded
    /// it; nobody can claim that for someone else.
    private func reconcileShare(_ s: VaultSession) async {
        guard let sharing, let t = s.teamStore, let mirror = s.mirror, s.hostsShare,
              let info = try? await sharing.info(of: s.vaultId) else { return }
        let state = await t.state
        var byUser: [String: UUID] = [:]
        var claims: [String: Int] = [:]
        var identities: [String: [UUID]] = [:]
        var requested: [UUID: ULID] = [:]
        // Members, former members and people asking to join, by who uploaded their request.
        let people = Set(state.everyone.keys).union(await t.pendingMembers().map(\.id))
        for id in people {
            guard let r = await t.joinRequest(of: id), let user = await mirror.creator(of: r.path) else { continue }
            byUser[user] = id
            claims[user, default: 0] += 1
            identities[user, default: []].append(id)
            requested[id] = r.id
        }
        // Each removal is acted on once per Mac, so a later re-invite of the same person survives.
        let handledKey = "dk.dinhkhanh.envault.handledRemovals.\(s.vaultId.uuidString)"
        var handled = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
        var onShare = Set<UUID>()
        for p in info.participants where !p.isOwner {
            // One Apple ID can stand behind several identities (a second join
            // request, a new identity after a reinstall): the strictest outcome
            // applies, so a second request can't opt anyone out of this upkeep.
            guard let user = p.userRecordName, let ids = identities[user] else { continue }
            let current = ids.filter { state.role(of: $0) != nil }
            if p.status == .accepted { onShare.formUnion(current) }
            do {
                if !current.isEmpty {
                    let canWrite = current.allSatisfy { state.role(of: $0)?.canWrite == true }
                    if p.status == .accepted, p.canWrite != canWrite {
                        _ = try await sharing.setPermission(of: p, canWrite: canWrite, on: s.vaultId)
                    }
                } else if let removed = ids.compactMap({ state.removedAt[$0] }).max(), !handled.contains(removed.string) {
                    // Not if they asked to join again since (invited back). A request
                    // dated ahead of now was made before, to pass for one made after.
                    let now = ULID(date: Date().addingTimeInterval(3600))
                    let askedAgain = ids.contains { id in requested[id].map { $0 > removed && $0 < now } ?? false }
                    if p.status == .accepted, !askedAgain {
                        _ = try await sharing.removeParticipant(p, from: s.vaultId)
                    }
                    handled.insert(removed.string)
                }
            } catch {
                errorMessage = "Couldn't update the iCloud share: \(error.localizedDescription)"
            }
        }
        UserDefaults.standard.set(Array(handled), forKey: handledKey)
        offShare[s.vaultId] = Set(byUser.values.filter { state.role(of: $0) != nil && !onShare.contains($0) })

        // FR-6: invitations nobody accepted within 7 days lapse; the role offered guides approval.
        var invites = Self.cloudInvites(s.vaultId)
        var offers: [UUID: ULID] = [:]
        var stillNeeded = Set<String>()
        for p in info.participants where !p.isOwner {
            guard let email = p.email?.lowercased(), let id = invites[email].flatMap(ULID.init(string:)) else { continue }
            if p.status == .pending, let offer = state.invites[id], offer.expiresAt < Date() {
                _ = try? await sharing.removeParticipant(p, from: s.vaultId)
            } else if let user = p.userRecordName, claims[user] == 1, let member = byUser[user] {
                offers[member] = id
                // Kept until they are a member: then the email isn't needed on this Mac any more.
                if state.members[member] == nil { stillNeeded.insert(email) }
            } else if p.status != .removed {
                stillNeeded.insert(email)
            }
        }
        cloudInviteOffers[s.vaultId] = offers
        invites = invites.filter { stillNeeded.contains($0.key) }
        UserDefaults.standard.set(invites, forKey: Self.cloudInvitesKey(s.vaultId))
    }

    private static func cloudInvitesKey(_ vaultId: UUID) -> String { "dk.dinhkhanh.envault.cloudInvites.\(vaultId.uuidString)" }
    /// On the Mac that hosts an iCloud team's share: which invitation went to which email.
    private static func cloudInvites(_ vaultId: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cloudInvitesKey(vaultId)) as? [String: String] ?? [:]
    }
    /// Per iCloud team vault: the invitation each requester answered, matched through the share.
    private var cloudInviteOffers: [UUID: [UUID: ULID]] = [:]

    /// A join request with the invitation it answers filled in, also for iCloud
    /// teams, where the request itself can't name one.
    func withInvitation(_ p: PendingMember, in s: VaultSession) -> PendingMember {
        guard p.invitedAs == nil, !p.inviteLapsed, let id = cloudInviteOffers[s.vaultId]?[p.id],
              let offer = s.team?.invites[id] else { return p }
        var out = p
        out.invitedAs = offer.role
        out.inviteLapsed = p.requestedAt > offer.expiresAt
        return out
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
            storage: { [weak self] agent, vaultId in
                guard let self else { throw Agent.Failure("EnVault is quitting") }
                return try self.vaultStorageForCLI(agent: agent, vaultId: vaultId)
            },
            seen: { vaultId in
                let url = Self.seenURL(for: vaultId)
                return FileManager.default.fileExists(atPath: url.path) ? VaultSession.seen(at: url) : nil
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

        // A team vault's rules can only make this Mac's setting stricter (FR-23).
        let own = Prefs.agentPolicy
        // The app's own copy of the vault's rules wins over what the caller reports.
        let teamRules = r.teamVault.flatMap { id in sessions.first { $0.vaultId == id }?.team?.agentRules } ?? r.teamRules
        var policy = own.restricted(by: teamRules)
        if let agent = r.agent {
            func whose(_ ownAllows: Bool) -> String { ownAllows ? "this team vault's rules" : "Settings › AI Agents" }
            guard policy.enabled else { throw refuse("AI agents are turned off (\(whose(own.enabled)))") }
            if r.purpose == .reveal, policy.values == .never {
                throw refuse("EnVault doesn't show secret values to AI agents (\(whose(own.values != .never))); use `envault run` instead")
            }
            if r.purpose == .write, !policy.writes {
                throw refuse("AI agents may not change env files (\(whose(own.writes)))")
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
    /// container itself in iCloud mode, or a team vault's (`vaultId`; FR-22).
    /// Ciphertext; the key is a separate request, and team vaults unlock with it.
    private func vaultStorageForCLI(agent: String?, vaultId: UUID?) throws -> any VaultStorage {
        guard UserDefaults.standard.bool(forKey: Prefs.cliAgentEnabled) else {
            throw Agent.Failure("the command line is turned off in EnVault Settings › Command Line", denied: true)
        }
        if agent != nil, !Prefs.agentPolicy.enabled {
            throw Agent.Failure("AI agents are turned off in EnVault Settings › AI Agents", denied: true)
        }
        guard store != nil, let vaultURL else { throw Agent.Failure("no vault is open in EnVault") }
        if let vaultId, vaultId != self.vaultId {
            // Any team vault this Mac keeps, locked or not: the files are ciphertext.
            let root = sessions.first { $0.vaultId == vaultId }?.url ?? TeamFolders.restore(vaultId) ?? Self.localRoot(for: vaultId)
            guard TeamFeatures.enabled, FileManager.default.fileExists(atPath: root.appendingPathComponent(VaultHeader.fileName).path) else {
                throw Agent.Failure("this Mac has no team vault \(vaultId.uuidString.prefix(8)); open it in EnVault first")
            }
            return LocalFolderStorage(root: root)
        }
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
