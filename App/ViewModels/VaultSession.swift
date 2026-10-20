import SwiftUI
import VaultCore
import VaultSync

/// One open vault: its store, where its files live, how they sync, and the
/// value snapshots views render. `AppModel` owns the session and everything
/// that spans vaults (lock state, selection, Touch ID, the CLI agent).
@MainActor
@Observable
final class VaultSession {
    let store: any VaultContent
    let url: URL
    let vaultId: UUID
    let mode: AppModel.SyncMode
    /// Shown in the sidebar's vault switcher; a team vault's title once read.
    private(set) var name: String

    /// The personal vault's store (nil for a team vault).
    var personalStore: VaultStore? { store as? VaultStore }
    var teamStore: TeamVaultStore? { store as? TeamVaultStore }
    var isTeam: Bool { teamStore != nil }

    /// What a team vault's views show about its people (nil for the personal vault).
    struct TeamSnapshot: Equatable {
        var access: TeamAccess
        var members: [TeamMember]
        var pending: [PendingMember]
        var hasRequestedToJoin: Bool
        var lateEvents: Set<ULID>
        var needsRotation: Bool
        /// Everyone who was ever a member, by id (names in the history and the log).
        var names: [UUID: String]
        /// Items whose current value people who left could read, with who (FR-14).
        var exposed: [UUID: Set<UUID>]
        var log: [TeamLogEntry]
        /// What the team lets AI agents do (FR-23), nil = no team rule.
        var agentRules: TeamAgentRules?
        /// Projects and items AI agents never get (FR-24).
        var humansOnly: Set<UUID>
        /// The license the owner put in the vault (FR-28), and the event that did.
        var license: TeamVaultLicense?
        var licenseEvent: ULID?
        /// Invitations sent, with the role offered and when they lapse (FR-6).
        var invites: [ULID: TeamState.Invite]
        /// Accepted membership changes that went missing from the files: saving is paused.
        var missingEvents: Int
        func name(_ id: UUID) -> String { names[id] ?? "Someone" }
        var role: TeamRole? {
            switch access { case .member(let r), .awaitingKey(let r): r; default: nil }
        }
        var canManage: Bool { role?.canManage == true }
        var canWrite: Bool { if case .member(let r) = access { r.canWrite && !needsRotation } else { false } }
    }
    private(set) var team: TeamSnapshot?
    /// Where this Mac keeps the membership events it has applied (team vaults).
    @ObservationIgnored var seenURL: URL?
    /// An iCloud team vault in this person's own iCloud: this Mac edits its
    /// share. That's whoever created it, even after handing ownership on (FR-29),
    /// because a CloudKit zone can't move to another Apple ID.
    var hostsShare = false
    /// After a team vault synced: the owner's Mac keeps the CloudKit share in step.
    @ObservationIgnored var didSyncTeam: (VaultSession) async -> Void = { _ in }

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

    init(store: any VaultContent, url: URL, vaultId: UUID, mode: AppModel.SyncMode, name: String) {
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
        projects = await store.projects(includeDeleted: false)
        items = await store.allItems()
        if let t = teamStore { await reloadTeam(t) }
        didReload()
    }

    private func reloadTeam(_ t: TeamVaultStore) async {
        let state = await t.state
        var names: [UUID: String] = [:]
        for id in state.everyone.keys { if let n = await t.name(of: id) { names[id] = n } }
        var exposed: [UUID: Set<UUID>] = [:]
        for e in await t.exposedItems() { exposed[e.item.id] = e.readers }
        team = TeamSnapshot(access: await t.access, members: await t.members(), pending: await t.pendingMembers(),
                            hasRequestedToJoin: await t.hasRequestedToJoin, lateEvents: await t.lateEvents,
                            needsRotation: state.needsRotation, names: names, exposed: exposed, log: await t.log(),
                            agentRules: state.agentRules, humansOnly: state.humansOnly, license: await t.license, licenseEvent: state.licenseEvent,
                            invites: state.invites, missingEvents: await t.missingEvents.count)
        if let title = await t.title { name = title }
        // Locked meanwhile (auto-lock while this awaited): keep what was saved.
        if let seenURL, let seen = await t.seenStateIfUnlocked, let data = try? JSONEncoder().encode(seen) {
            try? FileManager.default.createDirectory(at: seenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: seenURL, options: .atomic)
        }
    }

    /// What this Mac had accepted of a team vault last time (an older plain
    /// list of event ids still reads).
    static func seen(at url: URL) -> TeamSeen {
        guard let data = try? Data(contentsOf: url) else { return TeamSeen() }
        return TeamSeen.decode(data)
    }

    /// Drops the decrypted snapshots (the store clears its own index on lock).
    func clear() {
        projects = []
        items = []
        team = nil
    }

    /// Picks up revisions written by other devices or the CLI.
    func refreshFromDisk() async {
        guard isUnlocked else { return }
        do {
            if try await store.refresh() {
                await reload()
                // Folder teams have no sync pass of their own: their changes arrive here.
                if mode == .folder, isTeam { await upkeep() }
            }
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
        mirror = CloudMirror(vaultId: vaultId, localRoot: url, stateURL: stateURL, transport: transport, hostsZone: !isTeam || hostsShare)
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
            try? await personalStore?.reloadHeader()
            await refreshFromDisk()
        }
        await upkeep()
        await didSyncTeam(self)
    }

    /// An admin's Mac repairs a team vault's keys after each sync or change
    /// from other Macs: rotation, missing copies, links. Nothing for other roles.
    func upkeep() async {
        guard let t = teamStore, isUnlocked else { return }
        do {
            if try await !t.maintain().isEmpty {
                await reload()
                schedulePush()
            }
        } catch {
            reportError("Team key upkeep failed: \(error.localizedDescription)")
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
