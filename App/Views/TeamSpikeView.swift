#if DEBUG
import SwiftUI
import AppKit
import CloudKit
import VaultCore
import VaultSync

/// Team phase 0 spike: zone-wide CloudKit sharing of the open iCloud vault
/// between two Apple IDs. Debug builds only (Vault › Team Spike…); nothing
/// here is product code. Results go in the Team plan doc.
@MainActor @Observable
final class TeamSpikeModel {
    static let shared = TeamSpikeModel()

    struct LogLine: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let isError: Bool
    }

    /// Written by `Write Probe`; the reader logs how long it took to arrive.
    struct Probe: Codable {
        var writtenAt: Date
        var by: String
    }

    var log: [LogLine] = []
    var share: VaultShareInfo?
    var sharedVaults: [SharedVaultRef] = []
    var busy = false
    /// The open iCloud vault, set by the view. Nil when the app is in folder mode.
    var ownerVaultId: UUID?

    private let sharing = CloudKitSharing()
    private let own = CloudKitTransport()
    private var tokens: [String: Data] = [:]
    private let host = Host.current().localizedName ?? "this Mac"
    private var subscribedShared = false

    private init() {
        NotificationCenter.default.addObserver(forName: .cloudKitPush, object: nil, queue: .main) { note in
            let sub = note.userInfo?["subscriptionID"] as? String
            MainActor.assumeIsolated { TeamSpikeModel.shared.pushReceived(subscriptionID: sub) }
        }
    }

    func note(_ text: String, error: Bool = false) {
        log.append(LogLine(date: Date(), text: text, isError: error))
    }

    private func run(_ label: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await body() } catch { note("\(label): \(error.localizedDescription)", error: true) }
        }
    }

    // MARK: Owner

    func shareVault() {
        guard let id = ownerVaultId else { return }
        run("Share") { [self] in
            share = try await sharing.shareVault(id, title: "EnVault vault")
            note("Shared vault-\(id.uuidString.prefix(8)); link \(share?.url?.absoluteString ?? "none yet")")
        }
    }

    func refreshShare() {
        guard let id = ownerVaultId else { return }
        run("Refresh share") { [self] in
            share = try await sharing.info(of: id)
            note(share == nil ? "Vault is not shared" : "Share has \(share!.participants.count) participants")
        }
    }

    func add(email: String, canWrite: Bool) {
        guard let id = ownerVaultId else { return }
        run("Add \(email)") { [self] in
            share = try await sharing.addParticipant(email: email, canWrite: canWrite, to: id)
            note("Added \(email) (\(canWrite ? "read-write" : "read-only")); send them the link")
        }
    }

    func setWrite(email: String, _ canWrite: Bool) {
        guard let id = ownerVaultId else { return }
        run("Permission \(email)") { [self] in
            share = try await sharing.setPermission(email: email, canWrite: canWrite, on: id)
            note("\(email) is now \(canWrite ? "read-write" : "read-only")")
        }
    }

    func remove(email: String) {
        guard let id = ownerVaultId else { return }
        run("Remove \(email)") { [self] in
            share = try await sharing.removeParticipant(email: email, from: id)
            note("Removed \(email)")
        }
    }

    func stopSharing() {
        guard let id = ownerVaultId else { return }
        run("Stop sharing") { [self] in
            try await sharing.stopSharing(id)
            share = nil
            note("Stopped sharing")
        }
    }

    func fetchOwn() {
        guard let id = ownerVaultId else { return }
        run("Fetch own zone") { [self] in try await fetch(own, vaultId: id, key: "private-\(id)", label: "Own zone") }
    }

    func writeOwnProbe() {
        guard let id = ownerVaultId else { return }
        run("Probe own zone") { [self] in try await writeProbe(own, vaultId: id, label: "Own zone") }
    }

    func deleteProbes() {
        guard let id = ownerVaultId else { return }
        run("Delete probes") { [self] in
            var token: Data?
            var probes: [String] = []
            var more = true
            while more {
                let c = try await own.fetchChanges(vaultId: id, since: token)
                probes += c.files.map(\.path).filter { $0.hasPrefix("spike/") }
                token = c.token
                more = c.moreComing
            }
            if !probes.isEmpty { try await own.delete(paths: probes, vaultId: id) }
            note("Deleted \(probes.count) probe files")
        }
    }

    // MARK: Participant

    func accept(url: String) {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return note("Not a URL", error: true) }
        run("Accept") { [self] in
            let ref = try await sharing.accept(url: u)
            note("Accepted vault-\(ref.vaultId.uuidString.prefix(8)) owned by \(ref.ownerName.prefix(10))…")
            try await refreshSharedNow()
        }
    }

    /// From `application(_:userDidAcceptCloudKitShareWith:)`: the link was opened from Mail, Messages or Safari.
    func accept(_ metadata: CKShare.Metadata) {
        note("Share link opened from outside the app")
        run("Accept") { [self] in
            let ref = try await sharing.accept(metadata)
            note("Accepted vault-\(ref.vaultId.uuidString.prefix(8))")
            try await refreshSharedNow()
        }
    }

    func refreshShared() { run("Shared vaults") { [self] in try await refreshSharedNow() } }

    private func refreshSharedNow() async throws {
        sharedVaults = try await sharing.sharedVaults()
        note("\(sharedVaults.count) vaults shared with this account")
        if !subscribedShared, let first = sharedVaults.first {
            try await sharing.transport(for: first).subscribe(first.vaultId)
            subscribedShared = true
            note("Subscribed to shared-database pushes")
        }
    }

    func fetch(_ ref: SharedVaultRef) {
        run("Fetch shared") { [self] in
            let t = sharing.transport(for: ref)
            try await t.ensureVault(ref.vaultId)
            try await fetch(t, vaultId: ref.vaultId, key: "shared-\(ref.ownerName)-\(ref.vaultId)", label: "Shared \(ref.vaultId.uuidString.prefix(8))")
        }
    }

    func writeProbe(_ ref: SharedVaultRef) {
        run("Probe shared") { [self] in try await writeProbe(sharing.transport(for: ref), vaultId: ref.vaultId, label: "Shared \(ref.vaultId.uuidString.prefix(8))") }
    }

    /// The whole data path a team member needs: mirror the shared zone into a
    /// scratch folder, open it with `VaultStore`, unlock with the owner's passphrase.
    func downloadAndUnlock(_ ref: SharedVaultRef, passphrase: String) {
        run("Download") { [self] in
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("team-spike", isDirectory: true)
            let root = base.appendingPathComponent(ref.vaultId.uuidString, isDirectory: true)
            let state = base.appendingPathComponent("\(ref.vaultId.uuidString).state.json")
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: state)
            let started = Date()
            let mirror = CloudMirror(vaultId: ref.vaultId, localRoot: root, stateURL: state, transport: sharing.transport(for: ref))
            let pulled = try await mirror.pull()
            let store = try await VaultStore.open(storage: LocalFolderStorage(root: root))
            _ = try await store.unlock(passphrase: passphrase)
            let projects = await store.projects().count
            let items = await store.allItems().count
            await store.lock()
            note(String(format: "Downloaded %d files and unlocked in %.1f s: %d projects, %d items", pulled, Date().timeIntervalSince(started), projects, items))
        }
    }

    func leave(_ ref: SharedVaultRef) {
        run("Leave") { [self] in
            try await sharing.leave(ref)
            note("Left vault-\(ref.vaultId.uuidString.prefix(8))")
            try await refreshSharedNow()
        }
    }

    // MARK: Shared helpers

    private func pushReceived(subscriptionID: String?) {
        note("Push received (\(subscriptionID ?? "no subscription id"))")
        if subscriptionID == "envault-shared" {
            for ref in sharedVaults { fetch(ref) }
        } else if ownerVaultId != nil {
            fetchOwn()
        }
    }

    private func fetch(_ t: CloudKitTransport, vaultId: UUID, key: String, label: String) async throws {
        var token = tokens[key]
        var files = 0, deleted = 0
        var more = true
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        while more {
            let c: CloudChanges
            do {
                c = try await t.fetchChanges(vaultId: vaultId, since: token)
            } catch CloudTransportError.tokenExpired {
                token = nil
                continue
            }
            for f in c.files {
                files += 1
                if f.path == VaultHeader.fileName {
                    let ok = (try? VaultHeader.decode(f.data))?.vaultId == vaultId
                    note("\(label): vault.json \(ok ? "decodes and matches the zone" : "does NOT match the zone")", error: !ok)
                }
                if f.path.hasPrefix("spike/"), let p = try? dec.decode(Probe.self, from: f.data) {
                    note(String(format: "%@: probe from %@ arrived %.1f s after it was written", label, p.by, Date().timeIntervalSince(p.writtenAt)))
                }
            }
            deleted += c.deletedPaths.count
            token = c.token
            more = c.moreComing
        }
        tokens[key] = token
        note("\(label): \(files) new or changed files, \(deleted) deleted")
    }

    private func writeProbe(_ t: CloudKitTransport, vaultId: UUID, label: String) async throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let path = "spike/\(ULID().string).json"
        try await t.upload([CloudFile(path: path, data: try enc.encode(Probe(writtenAt: Date(), by: host)))], vaultId: vaultId, overwrite: false)
        note("\(label): wrote \(path)")
    }
}

struct TeamSpikeView: View {
    @Environment(AppModel.self) private var model
    @State private var spike = TeamSpikeModel.shared
    @State private var email = ""
    @State private var canWrite = true
    @State private var link = ""
    @State private var passphrase = ""

    var body: some View {
        HSplitView {
            Form {
                ownerSection
                participantSection
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
            logView.frame(minWidth: 360)
        }
        .frame(minWidth: 820, minHeight: 560)
        .disabled(spike.busy)
        .onAppear {
            spike.ownerVaultId = model.syncMode == .iCloud ? model.vaultId : nil
            if spike.ownerVaultId != nil { spike.refreshShare() }
            spike.refreshShared()
        }
    }

    @ViewBuilder private var ownerSection: some View {
        Section("Owner: this Mac's iCloud vault") {
            if let id = spike.ownerVaultId {
                LabeledContent("Vault", value: "vault-\(id.uuidString.prefix(8))")
                if let share = spike.share {
                    if let url = share.url {
                        LabeledContent("Link") {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                    }
                    ForEach(share.participants, id: \.self) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name ?? p.email ?? p.userRecordName ?? "unknown")
                                Text("\(p.isOwner ? "owner" : (p.canWrite ? "read-write" : "read-only")) · \(p.status.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !p.isOwner, let e = p.email {
                                Button(p.canWrite ? "Make Read-Only" : "Allow Writes") { spike.setWrite(email: e, !p.canWrite) }
                                Button("Remove", role: .destructive) { spike.remove(email: e) }
                            }
                        }
                    }
                    HStack {
                        TextField("Apple ID email", text: $email)
                        Toggle("Can write", isOn: $canWrite)
                        Button("Add") { spike.add(email: email, canWrite: canWrite); email = "" }.disabled(email.isEmpty)
                    }
                    Button("Stop Sharing", role: .destructive) { spike.stopSharing() }
                } else {
                    Button("Share This Vault") { spike.shareVault() }
                }
                HStack {
                    Button("Fetch Own Zone") { spike.fetchOwn() }
                    Button("Write Probe") { spike.writeOwnProbe() }
                    Button("Delete Probes") { spike.deleteProbes() }
                }
            } else {
                Text("Open an iCloud vault on this Mac to share it.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var participantSection: some View {
        Section("Participant: vaults shared with this account") {
            HStack {
                TextField("Share link", text: $link)
                Button("Accept") { spike.accept(url: link); link = "" }.disabled(link.isEmpty)
            }
            SecureField("Owner's passphrase (for Download and Unlock)", text: $passphrase)
            ForEach(spike.sharedVaults, id: \.self) { ref in
                VStack(alignment: .leading, spacing: 6) {
                    Text("vault-\(ref.vaultId.uuidString.prefix(8))").font(.headline)
                    HStack {
                        Button("Fetch") { spike.fetch(ref) }
                        Button("Write Probe") { spike.writeProbe(ref) }
                        Button("Download and Unlock") { spike.downloadAndUnlock(ref, passphrase: passphrase) }.disabled(passphrase.isEmpty)
                        Button("Leave", role: .destructive) { spike.leave(ref) }
                    }
                }
            }
            Button("Refresh Shared Vaults") { spike.refreshShared() }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy") {
                    let f = ISO8601DateFormatter()
                    let text = spike.log.map { "\(f.string(from: $0.date)) \($0.isError ? "ERROR " : "")\($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear") { spike.log.removeAll() }
            }
            .padding(8)
            List(spike.log.reversed()) { line in
                VStack(alignment: .leading) {
                    Text(line.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                    Text(line.text).foregroundStyle(line.isError ? .red : .primary).textSelection(.enabled)
                }
            }
        }
    }
}
#endif
