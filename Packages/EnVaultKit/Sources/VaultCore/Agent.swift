import Foundation

/// Lets the `envault` CLI ask the running app for the vault key instead of the
/// passphrase. The app approves each request with Touch ID (or the Mac's login
/// password), so the CLI gets the same unlock the app has.
///
/// Transport: a CFMessagePort, i.e. a named Mach port registered by the app.
/// Nothing touches the file system (no other-app container access, no TCC
/// prompt) or the network. Requests are JSON; a key request returns at once
/// with a request id and the CLI polls until the user has answered.
public enum Agent {
    public static let portName = "dk.dinhkhanh.envault.agent"

    public struct Request: Codable, Sendable {
        public enum Op: String, Codable, Sendable { case info, requestKey, poll, storage }
        public var op: Op
        public var vaultId: UUID?
        public var requestId: UUID?
        /// What is asking, shown in the approval prompt ("envault run").
        public var client: String?
        /// The AI agent running the command ("Claude Code"), nil for a person.
        public var agent: String?
        /// What the key is for: `AIAgents.Purpose` raw value. Apps before 0.5 ignore it.
        public var purpose: String?
        /// What will be touched, for the prompt and the activity log ("api/prod.env").
        public var detail: String?
        /// `storage`: the file operation (`AppVaultStorage.Op`), "/"-joined vault paths, and data to write.
        public var storageOp: String?
        public var paths: [String]?
        public var data: Data?

        public init(op: Op, vaultId: UUID? = nil, requestId: UUID? = nil, client: String? = nil,
                    agent: String? = nil, purpose: String? = nil, detail: String? = nil) {
            self.op = op; self.vaultId = vaultId; self.requestId = requestId; self.client = client
            self.agent = agent; self.purpose = purpose; self.detail = detail
        }
    }

    /// A key request as the app sees it, labels already sanitized.
    public struct KeyRequest: Sendable {
        public var vaultId: UUID
        public var client: String
        public var agent: String?
        public var purpose: AIAgents.Purpose
        public var detail: String?
    }

    public struct Info: Codable, Sendable {
        public var vaultId: UUID?
        /// The vault folder the app has open (folder mode) or its local copy (iCloud mode).
        public var vaultPath: String?
        public var mode: String?
        public var locked: Bool
        public var appVersion: String
        /// The CLI inside the app bundle.
        public var cliPath: String?
        /// What AI agents may do (Settings › AI Agents). Nil from apps before 0.5.
        public var agents: AIAgents.Policy?
        public init(vaultId: UUID?, vaultPath: String?, mode: String?, locked: Bool, appVersion: String, cliPath: String?,
                    agents: AIAgents.Policy? = nil) {
            self.vaultId = vaultId; self.vaultPath = vaultPath; self.mode = mode; self.locked = locked
            self.appVersion = appVersion; self.cliPath = cliPath; self.agents = agents
        }
    }

    public struct Response: Codable, Sendable {
        public enum State: String, Codable, Sendable { case pending, granted }
        public var ok: Bool
        public var error: String?
        public var info: Info?
        public var requestId: UUID?
        public var state: State?
        public var key: Data?
        /// The user or a setting said no: the CLI must not fall back to another way in.
        public var denied: Bool?
        /// `storage` results.
        public var files: [Data]?
        public var exists: Bool?
        public var names: [String]?

        public init(ok: Bool, error: String? = nil, info: Info? = nil, requestId: UUID? = nil, state: State? = nil, key: Data? = nil, denied: Bool? = nil) {
            self.ok = ok; self.error = error; self.info = info; self.requestId = requestId; self.state = state; self.key = key
            self.denied = denied
        }
        public static func failure(_ e: String, denied: Bool = false) -> Response { Response(ok: false, error: e, denied: denied ? true : nil) }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        /// A refusal (user cancelled, or a setting forbids it), as opposed to "can't ask".
        public var denied: Bool
        public init(_ m: String, denied: Bool = false) { message = m; self.denied = denied }
        public var errorDescription: String? { message }
    }
}

// MARK: - Client (CLI side)

public struct AgentClient {
    private let port: CFMessagePort

    /// Nil when the app is not running (or is a build without the agent).
    public init?(name: String = Agent.portName) {
        guard let p = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }
        port = p
    }

    public func send(_ req: Agent.Request, timeout: TimeInterval = 5) throws -> Agent.Response {
        let data = try JSONEncoder().encode(req) as CFData
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, data, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let r = reply?.takeRetainedValue() else {
            throw Agent.Failure("EnVault did not answer (status \(status))")
        }
        return try JSONDecoder().decode(Agent.Response.self, from: r as Data)
    }

    public func info() throws -> Agent.Info {
        let r = try send(Agent.Request(op: .info))
        guard r.ok, let i = r.info else { throw Agent.Failure(r.error ?? "no info") }
        return i
    }

    /// Asks the app for the key of `vaultId`. Blocks while the user answers the
    /// Touch ID prompt, up to `timeout`.
    public func requestKey(vaultId: UUID, client: String, agent: String? = nil, purpose: AIAgents.Purpose = .use,
                           detail: String? = nil, timeout: TimeInterval = 120) throws -> VaultKey {
        let start = try send(Agent.Request(op: .requestKey, vaultId: vaultId, client: client,
                                           agent: agent, purpose: purpose.rawValue, detail: detail))
        guard start.ok, let id = start.requestId else { throw Agent.Failure(start.error ?? "refused", denied: start.denied == true) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(150_000)
            let r = try send(Agent.Request(op: .poll, requestId: id))
            guard r.ok else { throw Agent.Failure(r.error ?? "refused", denied: r.denied == true) }
            if r.state == .granted {
                guard let k = r.key, k.count == 32 else { throw Agent.Failure("malformed key") }
                return VaultKey(data: k)
            }
        }
        throw Agent.Failure("timed out waiting for approval in EnVault")
    }
}

// MARK: - Server (app side)

@MainActor
public final class AgentServer {
    public typealias InfoProvider = @MainActor () -> Agent.Info
    public typealias Authorizer = @MainActor (Agent.KeyRequest) async throws -> VaultKey
    /// The open vault's storage, for a CLI that can't read the app's container.
    /// Gets the requesting AI agent (nil for a person); throws to refuse.
    public typealias StorageProvider = @MainActor (_ agent: String?) throws -> any VaultStorage

    private let info: InfoProvider
    private let authorize: Authorizer
    private let storage: StorageProvider?
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    private enum Outcome { case pending, granted(VaultKey), failed(String, denied: Bool) }
    private var requests: [UUID: (outcome: Outcome, created: Date)] = [:]

    /// The running server; the C callback has no context to find it otherwise.
    fileprivate static var current: AgentServer?

    public init(info: @escaping InfoProvider, authorize: @escaping Authorizer, storage: StorageProvider? = nil) {
        self.info = info
        self.authorize = authorize
        self.storage = storage
    }

    /// Registers the port. False if the name is taken (another EnVault is running)
    /// or the sandbox refused it.
    @discardableResult
    public func start(name: String = Agent.portName) -> Bool {
        guard port == nil else { return true }
        var shouldFree: DarwinBoolean = false
        guard let p = CFMessagePortCreateLocal(nil, name as CFString, agentCallback, nil, &shouldFree) else { return false }
        port = p
        source = CFMessagePortCreateRunLoopSource(nil, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        Self.current = self
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        port = nil; source = nil
        if Self.current === self { Self.current = nil }
        requests = [:]
    }

    fileprivate func handle(_ data: Data) -> Data {
        let response: Agent.Response
        if let req = try? JSONDecoder().decode(Agent.Request.self, from: data) {
            response = respond(to: req)
        } else {
            response = .failure("bad request")
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }

    private func respond(to req: Agent.Request) -> Agent.Response {
        let now = Date()
        requests = requests.filter { now.timeIntervalSince($0.value.created) < 180 }
        switch req.op {
        case .info:
            return Agent.Response(ok: true, info: info())
        case .requestKey:
            guard let vaultId = req.vaultId else { return .failure("no vault id") }
            if requests.values.contains(where: { if case .pending = $0.outcome { true } else { false } }) {
                return .failure("another request is waiting for approval in EnVault")
            }
            let id = UUID()
            requests[id] = (.pending, now)
            let request = Agent.KeyRequest(
                vaultId: vaultId,
                client: Self.sanitize(req.client ?? "envault"),
                agent: req.agent.map { Self.sanitize($0, fallback: "AI agent") },
                purpose: req.purpose.flatMap(AIAgents.Purpose.init(rawValue:)) ?? .use,
                detail: req.detail.map { Self.sanitize($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 })
            Task { @MainActor in
                do {
                    let key = try await authorize(request)
                    requests[id]?.outcome = .granted(key)
                } catch let f as Agent.Failure {
                    requests[id]?.outcome = .failed(f.message, denied: f.denied)
                } catch {
                    requests[id]?.outcome = .failed(error.localizedDescription, denied: false)
                }
            }
            return Agent.Response(ok: true, requestId: id, state: .pending)
        case .storage:
            return serveStorage(req)
        case .poll:
            guard let id = req.requestId, let r = requests[id] else { return .failure("unknown request") }
            switch r.outcome {
            case .pending:
                return Agent.Response(ok: true, requestId: id, state: .pending)
            case .granted(let key):
                requests[id] = nil   // hand the key out once
                return Agent.Response(ok: true, requestId: id, state: .granted, key: key.data)
            case .failed(let e, let denied):
                requests[id] = nil
                return .failure(e, denied: denied)
            }
        }
    }

    /// File access to the open vault on behalf of the CLI. The files are
    /// ciphertext; the key still needs `requestKey`. Only reads and create-only
    /// writes (new revisions) are served, so a caller can add history but never
    /// replace or delete anything. The reply is synchronous: the work is a few
    /// local file reads.
    private func serveStorage(_ req: Agent.Request) -> Agent.Response {
        guard let provider = storage else { return .failure("this version of EnVault can't serve vault files") }
        guard let op = req.storageOp.flatMap(AppVaultStorage.Op.init(rawValue:)) else { return .failure("bad storage request") }
        let paths = (req.paths ?? []).compactMap(Self.vaultPath)
        guard !paths.isEmpty, paths.count == req.paths?.count else { return .failure("bad vault path") }
        if op == .writeNew, req.data == nil { return .failure("nothing to write") }
        let store: any VaultStorage
        do {
            store = try provider(req.agent.map { Self.sanitize($0, fallback: "AI agent") })
        } catch let f as Agent.Failure {
            return .failure(f.message, denied: f.denied)
        } catch {
            return .failure(error.localizedDescription)
        }
        let box = StorageResult()
        let done = DispatchSemaphore(value: 0)
        let data = req.data
        Task.detached {
            do {
                var r = Agent.Response(ok: true)
                switch op {
                case .exists: r.exists = try await store.exists(paths[0])
                case .read: r.files = [try await store.read(paths[0])]
                case .readMany: r.files = try await store.readMany(paths)
                case .list: r.names = try await store.list(paths[0])
                case .writeNew: try await store.writeNew(paths[0], data: data ?? Data())
                }
                box.set(r)
            } catch {
                box.set(.failure(error.localizedDescription))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 50) == .success else { return .failure("EnVault took too long reading the vault") }
        return box.value ?? .failure("no result")
    }

    /// "projects/<id>/items/…" → a VaultPath, rejecting anything that could leave the vault folder.
    static func vaultPath(_ s: String) -> VaultPath? {
        if s.isEmpty { return VaultPath([]) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let ok = parts.allSatisfy { p in
            !p.isEmpty && p != "." && p != ".." && p.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
        }
        return ok ? VaultPath(parts) : nil
    }

    private final class StorageResult: @unchecked Sendable {
        private let lock = NSLock()
        private var r: Agent.Response?
        func set(_ v: Agent.Response) { lock.withLock { r = v } }
        var value: Agent.Response? { lock.withLock { r } }
    }

    /// The client label is untrusted text that ends up in a system prompt.
    static func sanitize(_ s: String, fallback: String = "envault") -> String {
        let cleaned = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_./:@".unicodeScalars.contains($0) }
        let out = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? fallback : String(out.prefix(60))
    }
}

private func agentCallback(_ port: CFMessagePort?, _ msgid: Int32, _ data: CFData?, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    let input = (data as Data?) ?? Data()
    let output: Data? = MainActor.assumeIsolated { AgentServer.current?.handle(input) }
    // The port releases the reply after sending it.
    return output.map { Unmanaged.passRetained($0 as CFData) }
}

// MARK: - Vault files through the app (CLI side)

/// Reads the vault the EnVault app has open through the app itself. In iCloud
/// mode the vault lives in the app's sandbox container, which macOS doesn't
/// let other programs read (Terminal, an editor, an MCP host) without the
/// "access data from other apps" permission. Ciphertext only; read-mostly:
/// the app refuses to replace or delete files for the CLI.
public struct AppVaultStorage: VaultStorage {
    public enum Op: String, Codable, Sendable { case exists, read, readMany, list, writeNew }

    public let agent: String?
    public let portName: String

    public init(agent: String?, portName: String = Agent.portName) {
        self.agent = agent
        self.portName = portName
    }

    private func call(_ op: Op, _ paths: [VaultPath], data: Data? = nil) throws -> Agent.Response {
        guard let client = AgentClient(name: portName) else { throw Agent.Failure("EnVault quit; open it again") }
        var req = Agent.Request(op: .storage, agent: agent)
        req.storageOp = op.rawValue
        req.paths = paths.map(\.string)
        req.data = data
        let r = try client.send(req, timeout: 60)
        guard r.ok else { throw Agent.Failure(r.error ?? "EnVault refused", denied: r.denied == true) }
        return r
    }

    public func exists(_ path: VaultPath) async throws -> Bool { try call(.exists, [path]).exists ?? false }

    public func read(_ path: VaultPath) async throws -> Data {
        guard let d = try call(.read, [path]).files?.first else { throw VaultError.io("EnVault returned no data for \(path)") }
        return d
    }

    public func readMany(_ paths: [VaultPath]) async throws -> [Data] {
        guard !paths.isEmpty else { return [] }
        let files = try call(.readMany, paths).files ?? []
        guard files.count == paths.count else { throw VaultError.io("EnVault returned \(files.count) of \(paths.count) files") }
        return files
    }

    public func writeNew(_ path: VaultPath, data: Data) async throws { _ = try call(.writeNew, [path], data: data) }

    public func writeReplace(_ path: VaultPath, data: Data) async throws {
        throw VaultError.io("the command line can't replace \(path) in an iCloud vault; do this in the EnVault app")
    }

    public func delete(_ path: VaultPath) async throws {
        throw VaultError.io("the command line can't delete files in an iCloud vault; do this in the EnVault app")
    }

    public func list(_ directory: VaultPath) async throws -> [String] { try call(.list, [directory]).names ?? [] }
}
