import SwiftUI
import VaultCore
import VaultSync

/// One open vault: its store, where its files live, how they sync, and the
/// value snapshots views render. `AppModel` owns the session and everything
/// that spans vaults (lock state, selection, Touch ID, the CLI agent).
@MainActor
@Observable
final class VaultSession {
    let store: VaultStore
    let url: URL
    let vaultId: UUID
    let mode: AppModel.SyncMode
    /// Shown in the sidebar's vault switcher.
    let name: String

    private(set) var projects: [Project] = []
    private(set) var items: [Item] = []
    private(set) var lastRefresh: Date?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastCloudSync: Date?

    /// Set by the model. New revisions are only indexed while unlocked.
    var isUnlocked = false
    /// After `projects` and `items` change.
    @ObservationIgnored var didReload: () -> Void = {}
    @ObservationIgnored var reportError: (String) -> Void = { _ in }

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var mirror: CloudMirror?
    @ObservationIgnored private var cloudTimer: Task<Void, Never>?
    @ObservationIgnored private var pushDebounce: Task<Void, Never>?

    init(store: VaultStore, url: URL, vaultId: UUID, mode: AppModel.SyncMode, name: String) {
        self.store = store
        self.url = url
        self.vaultId = vaultId
        self.mode = mode
        self.name = name
    }

    /// Stops watching and syncing. The store itself is left as it is.
    func close() {
        stopWatching()
        stopCloud()
    }

    // MARK: - Index

    func reload() async {
        projects = await store.projects()
        items = await store.allItems()
        didReload()
    }

    /// Drops the decrypted snapshots (the store clears its own index on lock).
    func clear() {
        projects = []
        items = []
    }

    /// Picks up revisions written by other devices or the CLI.
    func refreshFromDisk() async {
        guard isUnlocked else { return }
        do {
            if try await store.refresh() { await reload() }
            lastRefresh = Date()
        } catch {
            reportError("Sync read failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Folder watching

    /// Watches the vault folder from the moment it is opened. Locked: only
    /// cloud pushes happen. Unlocked: new revisions are also indexed.
    func startWatching() {
        stopWatching()
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

    // MARK: - iCloud (CloudKit) mode

    func startCloud(transport: CloudVaultTransport, stateURL: URL) {
        mirror = CloudMirror(vaultId: vaultId, localRoot: url, stateURL: stateURL, transport: transport)
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
            try? await store.reloadHeader()
            await refreshFromDisk()
        }
    }

    /// Local files changed (our own writes): push soon, coalesced.
    func schedulePush() {
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
}
