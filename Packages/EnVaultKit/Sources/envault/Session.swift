import Foundation
import Security
import VaultCore
import EnvKit
import LicenseKit

// MARK: - Errors and exit codes

/// Stable exit codes, so scripts and AI agents can tell "ask the user" from "no".
enum ExitCode: Int32 {
    case error = 1
    case findings = 2      // `scan` found secrets
    case notFound = 3      // no such project or item
    case needsUser = 4     // locked, or needs approval nobody can give from here
    case denied = 5        // the user or a setting refused
    case usage = 64

    var name: String {
        switch self {
        case .error: "error"
        case .findings: "findings"
        case .notFound: "not_found"
        case .needsUser: "needs_user"
        case .denied: "denied"
        case .usage: "usage"
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    var code: ExitCode
    init(_ d: String, code: ExitCode = .error) { description = d; self.code = code }

    /// Any error as a CLIError: the app's refusals keep their meaning.
    static func from(_ error: Error) -> CLIError {
        switch error {
        case let e as CLIError: e
        case let f as Agent.Failure: CLIError("EnVault: \(f.message)", code: f.denied ? .denied : .error)
        default: CLIError(error.localizedDescription)
        }
    }
}

// MARK: - Output

enum Out {
    static func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func json<T: Encodable>(_ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = (try? enc.encode(value)) ?? Data("null".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

// MARK: - Opening and unlocking the vault

/// Who is running `envault`, and how it may get the vault key.
struct Session {
    var root: URL
    /// The AI agent running us ("Claude Code"), nil for a person.
    var agent: String?
    /// May ask the EnVault app (ENVAULT_NO_APP unset).
    var useApp: Bool
    /// Shown in EnVault's approval prompt ("envault run").
    var client: String
    /// May prompt for the passphrase. Never true for agents.
    var interactive: Bool
    /// Only `envault unlock`'s cached key; nothing that could prompt (shell hooks).
    var cachedOnly = false
    /// `--team`: a team vault (name or id) instead of the personal vault (FR-22).
    var team: String?

    /// An iCloud-mode vault lives in the app's sandbox container, which macOS
    /// won't let Terminal (or an editor, or an MCP host) read without asking.
    var isInAppContainer: Bool {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return root.standardizedFileURL.path.hasPrefix(home + "/Library/Containers/dk.dinhkhanh.envault/")
    }

    /// The vault's files: read directly, or through the app for a vault in its container.
    func storage() throws -> any VaultStorage {
        guard isInAppContainer, useApp else { return LocalFolderStorage(root: root) }
        guard let app = appAgent(launch: true) else {
            throw CLIError("this vault is kept inside the EnVault app (iCloud mode): open EnVault so envault can read it", code: .needsUser)
        }
        // Just launched: give it a moment to open the vault.
        var info = try? app.info()
        for _ in 0..<50 where info?.vaultPath == nil {
            usleep(200_000)
            info = try? app.info()
        }
        guard let path = info?.vaultPath else { throw CLIError("EnVault has no vault open", code: .needsUser) }
        guard URL(fileURLWithPath: path).standardizedFileURL.path == root.standardizedFileURL.path else {
            throw CLIError("EnVault has a different vault open (\(path)); open this one in EnVault", code: .needsUser)
        }
        return AppVaultStorage(agent: agent)
    }

    func open() async throws -> VaultStore {
        let me = DeviceIdentity.current()
        return try await VaultStore.open(storage: try storage(),
                                         device: DeviceIdentity(id: me.id, name: me.name + (agent == nil ? " (cli)" : " (\(agent!))")))
    }

    /// Opens the vault and unlocks it for `purpose`. `detail` names what is
    /// touched ("api/.env"), for the approval prompt and EnVault's activity log.
    func unlocked(_ purpose: AIAgents.Purpose, _ detail: String? = nil) async throws -> VaultStore {
        let store = try await open()
        let vaultId = await store.vaultId
        if let agent {
            try await unlockForAgent(store, vaultId: vaultId, agent: agent, purpose: purpose, detail: detail)
            return store
        }
        if let cached = CLIKeyCache.load(vaultId: vaultId) {
            try await store.unlock(vaultKey: cached)
            return store
        }
        if cachedOnly { throw CLIError("no cached key", code: .needsUser) }
        if let p = Self.envPassphrase {
            try await store.unlock(passphrase: p)
            return store
        }
        if let key = keyFromApp(vaultId: vaultId, purpose: purpose, detail: detail), (try? await store.unlock(vaultKey: key)) != nil {
            return store
        }
        guard interactive else {
            throw CLIError("the vault is locked: start EnVault, run `envault unlock`, or set ENVAULT_PASSPHRASE", code: .needsUser)
        }
        try await store.unlock(passphrase: Self.promptPassphrase())
        return store
    }

    // MARK: Team vaults (FR-22)

    /// The vault a command works on: the personal vault, or with `--team` one
    /// of the team vaults the person belongs to.
    func content(_ purpose: AIAgents.Purpose, _ detail: String? = nil) async throws -> any VaultContent {
        guard let team else { return try await unlocked(purpose, detail) }
        guard let agent else {
            let store = try await teamVault(team, purpose, detail).store
            if purpose == .write { try await Self.checkWritable(store) }
            return store
        }
        // An agent: the team's rules are inside the vault, so open it for use
        // first, then have EnVault approve the real purpose under those rules (FR-23).
        let (store, personalId) = try await teamVault(team, .use, detail)
        let rules = await store.state.agentRules
        if purpose != .use || rules != nil {
            try approveUnderTeamRules(rules, agent: agent, purpose: purpose, vaultId: personalId, teamVault: store.vaultId,
                                      detail: "team \(team)" + (detail.map { ": \($0)" } ?? ""))
        }
        await store.hideHumansOnly()   // FR-24
        if purpose == .write { try await Self.checkWritable(store) }
        return store
    }

    /// FR-27: a team vault whose license lapsed past the grace period is read-only
    /// here too. (Revoked keys are only known to the app; it ships the list.)
    static func checkWritable(_ store: TeamVaultStore) async throws {
        guard let verifier = try? LicenseVerifier(publicKeyBase64: VendorKey.licensePublicKey) else { return }
        let status = TeamLicenseStatus.evaluate(await store.license?.entitlement, verifier: verifier)
        guard status.allowsWrites else {
            throw CLIError("this team vault is read-only: its Team license has lapsed. Nothing is lost; the owner renews it in EnVault", code: .denied)
        }
    }

    /// Asks EnVault again with the team's rules applied, or, without the app,
    /// applies them here. Throws when they refuse.
    private func approveUnderTeamRules(_ rules: TeamAgentRules?, agent: String, purpose: AIAgents.Purpose, vaultId: UUID, teamVault: UUID, detail: String) throws {
        if let app = appAgent(launch: true) {
            do {
                _ = try app.requestKey(vaultId: vaultId, client: client, agent: agent, purpose: purpose, detail: detail, teamRules: rules, teamVault: teamVault)
                return
            } catch let f as Agent.Failure {
                throw CLIError("EnVault: \(f.message)", code: f.denied ? .denied : .needsUser)
            }
        }
        // No app: an agent never reads values without the user's approval in it.
        if purpose == .reveal {
            throw CLIError("reading secret values needs the user's approval in the EnVault app (EnVault is not available). Ask the user.", code: .needsUser)
        }
        if rules?.enabled == false { throw CLIError("this team vault doesn't allow AI agents", code: .denied) }
        if purpose == .write, rules?.writes == false { throw CLIError("this team vault doesn't let AI agents change env files", code: .denied) }
    }

    struct TeamVault {
        var id: UUID
        var title: String?
        var access: TeamAccess
        var store: TeamVaultStore
    }

    /// Every team vault the personal vault remembers, unlocked with this
    /// person's identity. One approval covers them all: it unlocks the personal vault.
    func teamVaults(_ purpose: AIAgents.Purpose, _ detail: String? = nil) async throws -> [TeamVault] {
        try await teamVaultsWithPersonal(purpose, detail).vaults
    }

    private func teamVaultsWithPersonal(_ purpose: AIAgents.Purpose, _ detail: String?, only id: UUID? = nil) async throws -> (vaults: [TeamVault], personalId: UUID) {
        let personal = try await unlocked(purpose, detail)
        guard let me = try await personal.identity() else {
            throw CLIError("this vault has no Team identity yet: set one up in EnVault › Settings", code: .notFound)
        }
        var out: [TeamVault] = []
        for record in await personal.teams() where id == nil || record.vaultId == id {
            guard record.kind == TeamRecord.cloudKit || record.kind == TeamRecord.folder else { continue }
            do {
                let store = try await TeamVaultStore.open(storage: try teamStorage(record), device: device, owner: record.ownerKey)
                guard store.vaultId == record.vaultId else { throw CLIError("the folder for team vault \(record.vaultId.uuidString.prefix(8)) holds a different vault") }
                // The app's history of this vault, so missing changes and backdated revisions are caught here too.
                let access = try await store.unlock(identity: me, seen: try teamSeen(record.vaultId))
                out.append(TeamVault(id: record.vaultId, title: await store.title, access: access, store: store))
            } catch where id == nil {
                // One unreachable team vault (a folder team not located on this Mac) doesn't hide the others.
                Out.stderr("skipping team vault \(record.vaultId.uuidString.prefix(8)): \(CLIError.from(error).description)")
            }
        }
        return (out, await personal.vaultId)
    }

    /// One team vault by id (or its first 8 characters) or name, with the personal vault's id.
    func teamVault(_ selector: String, _ purpose: AIAgents.Purpose, _ detail: String?) async throws -> (store: TeamVaultStore, personalId: UUID) {
        let what = "team \(selector)" + (detail.map { ": \($0)" } ?? "")
        let byId = UUID(uuidString: selector)
        let (all, personalId) = try await teamVaultsWithPersonal(purpose, what, only: byId)
        let matches = byId != nil ? all : all.filter {
            $0.title?.localizedCaseInsensitiveCompare(selector) == .orderedSame
                || (selector.count >= 8 && $0.id.uuidString.lowercased().hasPrefix(selector.lowercased()))
        }
        guard matches.count == 1, let match = matches.first else {
            let names = all.map { "\($0.title ?? "untitled")  (\($0.id.uuidString.prefix(8)))" }.joined(separator: ", ")
            throw CLIError(matches.isEmpty ? "no team vault \(selector)" + (names.isEmpty ? "" : "; yours: \(names)")
                                           : "\(selector) matches several team vaults; use the id: \(names)", code: .notFound)
        }
        return (match.store, personalId)
    }

    /// A team vault's files, read through the EnVault app: iCloud teams live
    /// in its container, and only it knows where a folder team is on this Mac.
    /// With ENVAULT_NO_APP, iCloud teams are read from the container directly.
    private func teamStorage(_ record: TeamRecord) throws -> any VaultStorage {
        let vaultId = record.vaultId
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let local = URL(fileURLWithPath: home + "/Library/Containers/dk.dinhkhanh.envault/Data/Library/Application Support/EnVault/Vaults/\(vaultId.uuidString)")
        guard useApp else {
            guard record.kind == TeamRecord.cloudKit else {
                throw CLIError("folder-mode team vaults are found through the EnVault app; unset ENVAULT_NO_APP", code: .needsUser)
            }
            return LocalFolderStorage(root: local)
        }
        guard appAgent(launch: true) != nil else {
            throw CLIError("team vaults are kept inside the EnVault app: open EnVault so envault can read them", code: .needsUser)
        }
        return AppVaultStorage(agent: agent, vaultId: vaultId)
    }

    /// What the app had accepted of a team vault. The CLI only reads it: the
    /// app keeps it. Without an answer the vault isn't opened, since reading it
    /// as a Mac with no history would accept what the app refuses.
    private func teamSeen(_ vaultId: UUID) throws -> TeamSeen {
        guard useApp else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            let url = URL(fileURLWithPath: home + "/Library/Containers/dk.dinhkhanh.envault/Data/Library/Application Support/" + TeamSeen.fileName(vaultId: vaultId))
            guard FileManager.default.fileExists(atPath: url.path) else { return TeamSeen() }
            return TeamSeen.decode(try Data(contentsOf: url))
        }
        guard let app = appAgent(launch: true) else {
            throw CLIError("team vaults are kept inside the EnVault app: open EnVault so envault can read them", code: .needsUser)
        }
        do { return try app.teamSeen(vaultId: vaultId) ?? TeamSeen() } catch {
            throw CLIError("EnVault: \(error.localizedDescription). Update EnVault.", code: .needsUser)
        }
    }

    private var device: DeviceIdentity {
        let me = DeviceIdentity.current()
        return DeviceIdentity(id: me.id, name: me.name + (agent == nil ? " (cli)" : " (\(agent!))"))
    }

    /// Agents go through the app whenever it can be reached, so its settings
    /// and activity log apply. Without the app they may use `envault unlock`'s
    /// cached key (or ENVAULT_PASSPHRASE), but never to read values.
    private func unlockForAgent(_ store: VaultStore, vaultId: UUID, agent: String, purpose: AIAgents.Purpose, detail: String?) async throws {
        var appError: String?
        if let app = appAgent(launch: true) {
            Out.stderr("Asking EnVault for access (the user may need to approve)…")
            do {
                let key = try app.requestKey(vaultId: vaultId, client: client, agent: agent, purpose: purpose, detail: detail)
                try await store.unlock(vaultKey: key)
                return
            } catch let f as Agent.Failure where f.denied {
                throw CLIError("EnVault: \(f.message)", code: .denied)
            } catch {
                appError = error.localizedDescription
            }
        }
        let why = appError.map { " (EnVault: \($0))" } ?? (useApp ? " (EnVault is not available)" : "")
        guard purpose != .reveal else {
            throw CLIError("reading secret values needs the user's approval in the EnVault app\(why). Ask the user.", code: .needsUser)
        }
        if let cached = CLIKeyCache.load(vaultId: vaultId) {
            try await store.unlock(vaultKey: cached)
        } else if let p = Self.envPassphrase {
            try await store.unlock(passphrase: p)
        } else {
            throw CLIError("the vault is locked\(why). Ask the user to open EnVault, or to run `envault unlock` in their own terminal.", code: .needsUser)
        }
    }

    /// The EnVault app's agent, launching the app in the background if needed.
    func appAgent(launch: Bool) -> AgentClient? {
        guard useApp else { return nil }
        if let c = AgentClient() { return c }
        guard launch else { return nil }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", "-b", "dk.dinhkhanh.envault"]
        open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
        guard (try? open.run()) != nil else { return nil }
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { return nil }
        for _ in 0..<40 {
            usleep(200_000)
            if let c = AgentClient() { return c }
        }
        return nil
    }

    /// Asks the app for the key (Touch ID prompt in EnVault). Nil if the app isn't
    /// available or said no; prints why.
    func keyFromApp(vaultId: UUID, purpose: AIAgents.Purpose = .use, detail: String? = nil) -> VaultKey? {
        guard let agent = appAgent(launch: true) else { return nil }
        Out.stderr("Approve in EnVault (Touch ID)…")
        do {
            return try agent.requestKey(vaultId: vaultId, client: client, purpose: purpose, detail: detail)
        } catch {
            Out.stderr("EnVault: \(error.localizedDescription)")
            return nil
        }
    }

    static var envPassphrase: String? {
        guard let p = ProcessInfo.processInfo.environment["ENVAULT_PASSPHRASE"], !p.isEmpty else { return nil }
        return p
    }

    static func promptPassphrase() throws -> String {
        guard let c = getpass("Vault passphrase: ") else { throw CLIError("no passphrase", code: .needsUser) }
        return String(cString: c)
    }
}

// MARK: - Items

func find(_ store: any VaultContent, _ projectName: String, _ itemName: String) async throws -> Item {
    if let team = store as? TeamVaultStore, await team.isHiddenAsHumansOnly(project: projectName, item: itemName) {
        throw CLIError("\(projectName)/\(itemName) is marked for people only in this team vault: ask the user", code: .denied)
    }
    guard let p = await store.projects(includeDeleted: false).first(where: { $0.name == projectName }) else {
        throw CLIError("no project named \(projectName)", code: .notFound)
    }
    guard let item = await store.items(in: p.id).first(where: { $0.name == itemName }) else {
        throw CLIError("no item named \(itemName) in \(projectName)", code: .notFound)
    }
    return item
}

func envDoc(_ item: Item) throws -> EnvDocument {
    guard case .envFile(let text) = item.payload else { throw CLIError("\(item.name) is not an env file") }
    return DotEnv.parse(text)
}

/// Creates or updates an env file (and its project). Returns what happened.
@discardableResult
func upsert(_ store: any VaultContent, project: String, item: String, text: String) async throws -> String {
    var created: [String] = []
    if await store.projects(includeDeleted: false).first(where: { $0.name == project }) == nil {
        try await store.createProject(name: project, tags: [])
        created.append("created project \(project)")
    }
    guard let p = await store.projects(includeDeleted: false).first(where: { $0.name == project }) else { throw CLIError("project \(project) vanished") }
    if let existing = await store.items(in: p.id).first(where: { $0.name == item }) {
        if existing.payload.primaryText == text { return "\(project)/\(item) unchanged" }
        try await store.updateItem(existing.id, name: nil, tags: nil, payload: .envFile(text: text), projectId: nil)
        created.append("updated \(project)/\(item)")
    } else {
        try await store.createItem(in: p.id, name: item, payload: .envFile(text: text), tags: [])
        created.append("created \(project)/\(item)")
    }
    return created.joined(separator: "\n")
}

/// Sets and removes variables in an env file, creating it if needed.
@discardableResult
func editEnv(_ store: any VaultContent, project: String, item: String, set: [(key: String, value: String)], unset: [String]) async throws -> String {
    for k in set.map(\.key) + unset where !DotEnv.isValidKey(k) { throw CLIError("\(k) is not a valid variable name", code: .usage) }
    var doc = DotEnv.parse("")
    if let existing = try? await find(store, project, item) { doc = try envDoc(existing) }
    for k in unset where doc[k] == nil { throw CLIError("no variable \(k) in \(project)/\(item)", code: .notFound) }
    for (k, v) in set { doc = doc.setting(k, to: v) }
    for k in unset { doc = doc.removing(k) }
    return try await upsert(store, project: project, item: item, text: doc.text)
}

/// A random secret: 32 bytes, base64url without padding (43 characters).
func generateSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// MARK: - Running commands with secrets, output redacted

enum Runner {
    struct Result { var status: Int32; var timedOut: Bool }

    /// Runs `argv` (through /usr/bin/env) with `env`, feeding its stdout and
    /// stderr through a redactor for `doc` into the sinks. Stdin is inherited
    /// unless `closeStdin`. Returns once the process exits; output still held by
    /// background children is given up to two seconds.
    static func run(_ argv: [String], env: [String: String], cwd: String? = nil, redact doc: EnvDocument,
                    closeStdin: Bool = false, timeout: TimeInterval? = nil,
                    stdout: @escaping @Sendable (Data) -> Void, stderr: @escaping @Sendable (Data) -> Void) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if closeStdin { p.standardInput = FileHandle.nullDevice }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        let group = DispatchGroup()
        for (handle, sink) in [(out.fileHandleForReading, stdout), (err.fileHandleForReading, stderr)] {
            group.enter()
            Thread.detachNewThread {
                var r = EnvRedactor(doc)
                while true {
                    let d = handle.availableData
                    if d.isEmpty { break }
                    let red = r.feed(d)
                    if !red.isEmpty { sink(Data(red)) }
                }
                let rest = r.finish()
                if !rest.isEmpty { sink(Data(rest)) }
                group.leave()
            }
        }
        let timedOut = TimedOut()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [p] in
                if p.isRunning { timedOut.set(); p.terminate() }
            }
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return Result(status: p.terminationStatus, timedOut: timedOut.value)
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}

/// Collects a stream's output, keeping the last `limit` bytes.
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }

    func append(_ d: Data) {
        lock.withLock {
            data.append(d)
            if data.count > limit {
                dropped += data.count - limit
                data = Data(data.suffix(limit))
            }
        }
    }

    var text: String {
        lock.withLock {
            let s = String(decoding: data, as: UTF8.self)
            return dropped > 0 ? "[… \(dropped) earlier bytes not shown]\n" + s : s
        }
    }
}
