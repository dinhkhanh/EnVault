import Foundation

/// Lets the `evault` CLI ask the running app for the vault key instead of the
/// passphrase. The app approves each request with Touch ID (or the Mac's login
/// password), so the CLI gets the same unlock the app has.
///
/// Transport: a CFMessagePort, i.e. a named Mach port registered by the app.
/// Nothing touches the file system (no other-app container access, no TCC
/// prompt) or the network. Requests are JSON; a key request returns at once
/// with a request id and the CLI polls until the user has answered.
public enum Agent {
    public static let portName = "dk.dinhkhanh.evault.agent"

    public struct Request: Codable, Sendable {
        public enum Op: String, Codable, Sendable { case info, requestKey, poll }
        public var op: Op
        public var vaultId: UUID?
        public var requestId: UUID?
        /// What is asking, shown in the approval prompt ("evault run").
        public var client: String?

        public init(op: Op, vaultId: UUID? = nil, requestId: UUID? = nil, client: String? = nil) {
            self.op = op; self.vaultId = vaultId; self.requestId = requestId; self.client = client
        }
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
        public init(vaultId: UUID?, vaultPath: String?, mode: String?, locked: Bool, appVersion: String, cliPath: String?) {
            self.vaultId = vaultId; self.vaultPath = vaultPath; self.mode = mode; self.locked = locked
            self.appVersion = appVersion; self.cliPath = cliPath
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

        public init(ok: Bool, error: String? = nil, info: Info? = nil, requestId: UUID? = nil, state: State? = nil, key: Data? = nil) {
            self.ok = ok; self.error = error; self.info = info; self.requestId = requestId; self.state = state; self.key = key
        }
        public static func failure(_ e: String) -> Response { Response(ok: false, error: e) }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public init(_ m: String) { message = m }
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
            throw Agent.Failure("eVault did not answer (status \(status))")
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
    public func requestKey(vaultId: UUID, client: String, timeout: TimeInterval = 120) throws -> VaultKey {
        let start = try send(Agent.Request(op: .requestKey, vaultId: vaultId, client: client))
        guard start.ok, let id = start.requestId else { throw Agent.Failure(start.error ?? "refused") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(150_000)
            let r = try send(Agent.Request(op: .poll, requestId: id))
            guard r.ok else { throw Agent.Failure(r.error ?? "refused") }
            if r.state == .granted {
                guard let k = r.key, k.count == 32 else { throw Agent.Failure("malformed key") }
                return VaultKey(data: k)
            }
        }
        throw Agent.Failure("timed out waiting for approval in eVault")
    }
}

// MARK: - Server (app side)

@MainActor
public final class AgentServer {
    public typealias InfoProvider = @MainActor () -> Agent.Info
    public typealias Authorizer = @MainActor (_ vaultId: UUID, _ client: String) async throws -> VaultKey

    private let info: InfoProvider
    private let authorize: Authorizer
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    private enum Outcome { case pending, granted(VaultKey), failed(String) }
    private var requests: [UUID: (outcome: Outcome, created: Date)] = [:]

    /// The running server; the C callback has no context to find it otherwise.
    fileprivate static var current: AgentServer?

    public init(info: @escaping InfoProvider, authorize: @escaping Authorizer) {
        self.info = info
        self.authorize = authorize
    }

    /// Registers the port. False if the name is taken (another eVault is running)
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
                return .failure("another request is waiting for approval in eVault")
            }
            let id = UUID()
            requests[id] = (.pending, now)
            let client = Self.sanitize(req.client ?? "evault")
            Task { @MainActor in
                do {
                    let key = try await authorize(vaultId, client)
                    requests[id]?.outcome = .granted(key)
                } catch {
                    requests[id]?.outcome = .failed(error.localizedDescription)
                }
            }
            return Agent.Response(ok: true, requestId: id, state: .pending)
        case .poll:
            guard let id = req.requestId, let r = requests[id] else { return .failure("unknown request") }
            switch r.outcome {
            case .pending:
                return Agent.Response(ok: true, requestId: id, state: .pending)
            case .granted(let key):
                requests[id] = nil   // hand the key out once
                return Agent.Response(ok: true, requestId: id, state: .granted, key: key.data)
            case .failed(let e):
                requests[id] = nil
                return .failure(e)
            }
        }
    }

    /// The client label is untrusted text that ends up in a system prompt.
    static func sanitize(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_./:@".unicodeScalars.contains($0) }
        let out = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "evault" : String(out.prefix(60))
    }
}

private func agentCallback(_ port: CFMessagePort?, _ msgid: Int32, _ data: CFData?, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? {
    let input = (data as Data?) ?? Data()
    let output: Data? = MainActor.assumeIsolated { AgentServer.current?.handle(input) }
    // The port releases the reply after sending it.
    return output.map { Unmanaged.passRetained($0 as CFData) }
}
