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
        case noVault              // no folder chosen yet
        case locked
        case unlocked
    }

    private(set) var phase: Phase = .loading
    private(set) var vaultURL: URL?
    private(set) var vaultId: UUID?
    private(set) var projects: [Project] = []
    private(set) var items: [Item] = []
    private(set) var lastRefresh: Date?
    var errorMessage: String?
    var biometricsAvailable: Bool { KeychainVaultKeyStore.biometricsAvailable }
    private(set) var hasBiometricKey = false

    var selectedProjectId: UUID?
    var selectedItemId: UUID?
    var selectedToolId: String?
    var searchText = ""

    @ObservationIgnored private var store: VaultStore?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var autoLock: AutoLock!
    @ObservationIgnored private let keychain = KeychainVaultKeyStore()

    let tools = ToolRegistry.all

    init() {
        Prefs.registerDefaults()
        autoLock = AutoLock { [weak self] in self?.lock() }
    }

    // MARK: - Derived

    func items(in projectId: UUID) -> [Item] { items.filter { $0.projectId == projectId } }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectId } }
    var selectedItem: Item? { items.first { $0.id == selectedItemId } }
    var isInICloud: Bool { vaultURL.map(SyncLocations.isInsideICloudDrive) ?? false }

    // MARK: - Startup

    func start() async {
        guard phase == .loading else { return }
        #if DEBUG
        // Dev/testing: `eVault -vaultPath <dir> [-passphrase <pw>]` opens or creates a vault directly.
        if let path = UserDefaults.standard.string(forKey: "vaultPath") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if await VaultStore.vaultExists(in: LocalFolderStorage(root: url)) {
                await openVault(at: url)
            } else if let pw = UserDefaults.standard.string(forKey: "passphrase") {
                await createVault(at: url, passphrase: pw)
            }
            if phase != .loading { return }
        }
        #endif
        if let url = VaultLocation.restore() {
            await openVault(at: url)
        } else {
            phase = .noVault
        }
    }

    /// Opens (locked) the vault in `url`. Shows an error if there is none.
    func openVault(at url: URL) async {
        do {
            let storage = LocalFolderStorage(root: url)
            let s = try await VaultStore.open(storage: storage)
            try VaultLocation.save(url)
            store = s
            vaultURL = url
            vaultId = await s.vaultId
            hasBiometricKey = keychain.hasCachedKey(vaultId: vaultId!)
            phase = .locked
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if phase == .loading { phase = .noVault }
        }
    }

    func createVault(at url: URL, passphrase: String) async {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let storage = LocalFolderStorage(root: url)
            let s = try await VaultStore.create(storage: storage, passphrase: passphrase)
            try VaultLocation.save(url)
            store = s
            vaultURL = url
            vaultId = await s.vaultId
            hasBiometricKey = false
            errorMessage = nil
            await becameUnlocked()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forget the current vault location (does not delete any files).
    func closeVault() {
        lock()
        VaultLocation.forget()
        store = nil
        vaultURL = nil
        vaultId = nil
        phase = .noVault
    }

    // MARK: - Lock / unlock

    func unlock(passphrase: String, rememberWithBiometrics: Bool) async {
        guard let store else { return }
        do {
            let vk = try await store.unlock(passphrase: passphrase)
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
        guard let store, let vaultId else { return }
        do {
            guard let vk = try keychain.load(vaultId: vaultId) else { return } // cancelled or none
            try await store.unlock(vaultKey: vk)
            await becameUnlocked()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disableBiometrics() {
        guard let vaultId else { return }
        try? keychain.remove(vaultId: vaultId)
        hasBiometricKey = false
        UserDefaults.standard.set(false, forKey: Prefs.biometricUnlock)
    }

    func lock() {
        guard phase == .unlocked, let store else { return }
        watchTask?.cancel(); watchTask = nil
        watcher?.stop(); watcher = nil
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
        startWatching()
        autoLock.touch()
    }

    func userActivity() { autoLock.touch() }

    // MARK: - Sync / refresh

    private func startWatching() {
        guard let url = vaultURL else { return }
        let w = FolderWatcher(url: url)
        watcher = w
        watchTask = Task { [weak self] in
            for await _ in w.changes {
                guard let self, !Task.isCancelled else { return }
                await self.refreshFromDisk()
            }
        }
    }

    /// Picks up revisions written by other devices.
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
