import Foundation
import VaultCore
import EnvKit

/// `envault mcp`: EnVault as a Model Context Protocol server over stdio
/// (newline-delimited JSON-RPC), for Claude Code, Cursor, Codex and friends.
///
/// Same rules as an agent running the CLI: tools see names, not values;
/// `run_command` output is redacted; `get_values` needs the user's approval
/// in EnVault. Nothing but protocol messages may go to stdout.
@MainActor
struct MCPServer {
    var session: Session

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    EnVault keeps this user's secrets and env files. Use these tools to run commands with an env file's \
    variables set (output is redacted), to list variable names, and to add or change variables. You are not \
    meant to see secret values: never write them into files, code, commits or chat. get_values asks the user \
    for approval in EnVault; only use it when the user asked to see a value. If a tool reports needs_user, \
    tell the user what to do; if it reports denied, don't retry.
    """

    func run() async {
        var session = session
        while let line = readLine(strippingNewline: true) {
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            // Notifications (no id) need no answer.
            guard let id = msg["id"] else { continue }
            let params = msg["params"] as? [String: Any] ?? [:]
            switch msg["method"] as? String ?? "" {
            case "initialize":
                let client = (params["clientInfo"] as? [String: Any])?["name"] as? String
                if session.agent == nil { session.agent = Self.agentName(client) }
                let asked = params["protocolVersion"] as? String ?? ""
                reply(id, [
                    "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "envault", "title": "EnVault", "version": envaultVersion],
                    "instructions": Self.instructions,
                ])
            case "ping":
                reply(id, [String: Any]())
            case "tools/list":
                reply(id, ["tools": Self.tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                var s = session
                s.client = "envault mcp \(name)"
                do {
                    let text = try await call(name, arguments, s)
                    reply(id, ["content": [["type": "text", "text": text]], "isError": false])
                } catch {
                    let e = CLIError.from(error)
                    reply(id, ["content": [["type": "text", "text": "\(e.code.name): \(e.description)"]], "isError": true])
                }
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
            }
        }
    }

    /// "claude-code" → "Claude Code", for EnVault's approval prompt.
    static func agentName(_ client: String?) -> String {
        guard let c = client?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return "MCP client" }
        if c.contains(where: \.isUppercase) || c.contains(" ") { return c }
        return c.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Tools

    private func call(_ name: String, _ a: [String: Any], _ session: Session) async throws -> String {
        var session = session
        if let team = a["team"] as? String, !team.isEmpty { session.team = team }
        func str(_ k: String) throws -> String {
            guard let v = a[k] as? String, !v.isEmpty else { throw CLIError("missing argument \(k)", code: .usage) }
            return v
        }
        switch name {
        case "status":
            let info = session.useApp ? try? AgentClient()?.info() : nil
            return Self.json(StatusJSON(appRunning: info != nil, appVersion: info?.appVersion, vault: info?.vaultPath ?? session.root.path,
                                        mode: info?.mode, locked: info?.locked,
                                        cliKeyCached: info?.vaultId.map { CLIKeyCache.load(vaultId: $0) != nil } ?? false,
                                        agent: session.agent, agentPolicy: info?.agents))

        case "list_items":
            let store = try await session.content(.use)
            var projects: [ProjectJSON] = []
            for p in await store.projects(includeDeleted: false) {
                projects.append(ProjectJSON(name: p.name, items: await store.items(in: p.id).map {
                    ItemJSON(name: $0.name, kind: $0.kind.rawValue, revisions: $0.revisionCount)
                }))
            }
            return Self.json(projects)

        case "list_keys":
            let (project, item) = (try str("project"), try str("item"))
            let store = try await session.content(.use, "\(project)/\(item)")
            let doc = try envDoc(try await find(store, project, item))
            return Self.json(KeysJSON(project: project, item: item, keys: doc.entries.map {
                KeyJSON(name: $0.key, empty: $0.value.isEmpty, redacted: EnvRedactor.redacts($0))
            }))

        case "run_command":
            let (project, item, command) = (try str("project"), try str("item"), try str("command"))
            let cwd = a["cwd"] as? String
            let timeout = min(max((a["timeout_seconds"] as? Int) ?? 120, 1), 600)
            let store = try await session.content(.use, "\(project)/\(item)")
            let doc = try envDoc(try await find(store, project, item))
            var env = ProcessInfo.processInfo.environment
            for (k, v) in doc.values { env[k] = v }
            let out = TailBuffer(limit: 40_000), err = TailBuffer(limit: 20_000)
            let result = try Runner.run(["/bin/sh", "-c", command], env: env, cwd: cwd, redact: doc, closeStdin: true,
                                        timeout: TimeInterval(timeout), stdout: out.append, stderr: err.append)
            var text = result.timedOut ? "timed out after \(timeout)s (terminated)\n" : "exit code \(result.status)\n"
            let (o, e) = (out.text, err.text)
            if !o.isEmpty { text += "--- stdout ---\n\(o)\(o.hasSuffix("\n") ? "" : "\n")" }
            if !e.isEmpty { text += "--- stderr ---\n\(e)" }
            return text

        case "set_keys":
            let (project, item) = (try str("project"), try str("item"))
            var pairs: [(key: String, value: String)] = []
            for (k, v) in (a["values"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let s = v as? String else { throw CLIError("the value of \(k) must be a string", code: .usage) }
                pairs.append((k, s))
            }
            let generate = a["generate"] as? [String] ?? []
            pairs += generate.map { ($0, generateSecret()) }
            guard !pairs.isEmpty else { throw CLIError("nothing to set: pass values or generate", code: .usage) }
            let store = try await session.content(.write, "\(project)/\(item)")
            let msg = try await editEnv(store, project: project, item: item, set: pairs, unset: [])
            return msg + "\nset " + pairs.map(\.key).joined(separator: ", ")
                + (generate.isEmpty ? "" : "\ngenerated new random values for \(generate.joined(separator: ", ")) (32 bytes, base64url); they were not shown to you")

        case "unset_keys":
            let (project, item) = (try str("project"), try str("item"))
            guard let keys = a["keys"] as? [String], !keys.isEmpty else { throw CLIError("missing argument keys", code: .usage) }
            let store = try await session.content(.write, "\(project)/\(item)")
            return try await editEnv(store, project: project, item: item, set: [], unset: keys)

        case "get_values":
            let (project, item) = (try str("project"), try str("item"))
            let keys = a["keys"] as? [String]
            let detail = "\(project)/\(item)" + (keys.map { " (\($0.joined(separator: ", ")))" } ?? "")
            let store = try await session.content(.reveal, detail)
            let doc = try envDoc(try await find(store, project, item))
            let wanted = keys.map(Set.init)
            if let wanted, let missing = wanted.subtracting(doc.entries.map(\.key)).sorted().first {
                throw CLIError("no variable \(missing) in \(project)/\(item)", code: .notFound)
            }
            return doc.entries.filter { wanted?.contains($0.key) ?? true }.map(DotEnv.serialize).joined(separator: "\n")

        case "list_teams":
            let teams = try await session.teamVaults(.use, "the list of team vaults")
            return Self.json(teams.map { t -> TeamJSON in
                let role: String? = switch t.access { case .member(let r), .awaitingKey(let r): r.rawValue; default: nil }
                return TeamJSON(id: t.id.uuidString, name: t.title, role: role, access: role == nil ? "not a member" : "member")
            })

        case "scan":
            let dir = (a["path"] as? String) ?? FileManager.default.currentDirectoryPath
            return Self.json(findingsJSON(EnvHygiene.scan(folder: URL(fileURLWithPath: dir))))

        default:
            throw CLIError("unknown tool \(name)", code: .usage)
        }
    }

    static let team: [String: Any] = [
        "team": ["type": "string", "description": "A team vault's name or id (see list_teams). Omit for the user's personal vault."],
    ]

    static let projectItem: [String: Any] = team.merging([
        "project": ["type": "string", "description": "Project name in EnVault (see list_items)."],
        "item": ["type": "string", "description": "Env file name in the project, e.g. .env.production (see list_items)."],
    ]) { $1 }

    static func schema(_ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    static let tools: [[String: Any]] = [
        ["name": "status", "title": "EnVault status",
         "description": "Whether the EnVault app is running, which vault is open, whether it is locked, and what AI agents are allowed to do.",
         "inputSchema": schema(), "annotations": ["readOnlyHint": true]],
        ["name": "list_items", "title": "List env files",
         "description": "List projects and their env files / secrets (names only).",
         "inputSchema": schema(team), "annotations": ["readOnlyHint": true]],
        ["name": "list_teams", "title": "List team vaults",
         "description": "List the team vaults the user belongs to, with their role. Pass a team's name as `team` to the other tools to work in it.",
         "inputSchema": schema(), "annotations": ["readOnlyHint": true]],
        ["name": "list_keys", "title": "List variable names",
         "description": "List the variable names in an env file, without values. `redacted` tells whether run_command hides that value in output.",
         "inputSchema": schema(projectItem, required: ["project", "item"]), "annotations": ["readOnlyHint": true]],
        ["name": "run_command", "title": "Run a command with secrets",
         "description": "Run a shell command with an env file's variables set in its environment, e.g. tests, migrations, scripts or one-off API calls. Secret values in its output are replaced with [redacted:KEY]. Stdin is closed; the command is stopped after timeout_seconds, so don't use it for servers that keep running.",
         "inputSchema": schema(projectItem.merging([
            "command": ["type": "string", "description": "Shell command, run with /bin/sh -c."],
            "cwd": ["type": "string", "description": "Working directory (default: where the MCP server was started)."],
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600, "description": "Default 120."],
         ]) { $1 }, required: ["project", "item", "command"]),
         "annotations": ["openWorldHint": true]],
        ["name": "set_keys", "title": "Set variables",
         "description": "Add or change variables in an env file (created if missing). Use `generate` for new random secrets (API signing keys, session secrets) so the value is never shown to you. EnVault keeps every revision.",
         "inputSchema": schema(projectItem.merging([
            "values": ["type": "object", "additionalProperties": ["type": "string"], "description": "KEY → value."],
            "generate": ["type": "array", "items": ["type": "string"], "description": "Keys to set to a new random secret (32 bytes, base64url)."],
         ]) { $1 }, required: ["project", "item"]),
         "annotations": ["destructiveHint": false, "idempotentHint": true]],
        ["name": "unset_keys", "title": "Remove variables",
         "description": "Remove variables from an env file. EnVault keeps the previous revision.",
         "inputSchema": schema(projectItem.merging([
            "keys": ["type": "array", "items": ["type": "string"], "minItems": 1],
         ]) { $1 }, required: ["project", "item", "keys"]),
         "annotations": ["destructiveHint": true]],
        ["name": "get_values", "title": "Read secret values",
         "description": "Return secret values in KEY=value form. The user must approve this in EnVault (Touch ID) unless their settings allow it; it may be refused. Only use it when the user asked to see a value; to use secrets, prefer run_command.",
         "inputSchema": schema(projectItem.merging([
            "keys": ["type": "array", "items": ["type": "string"], "description": "Only these variables (default: all)."],
         ]) { $1 }, required: ["project", "item"]),
         "annotations": ["readOnlyHint": true]],
        ["name": "scan", "title": "Scan for leaked secrets",
         "description": "Look for API keys, tokens and real .env files in a source tree.",
         "inputSchema": schema(["path": ["type": "string", "description": "Folder (default: the working directory)."]]),
         "annotations": ["readOnlyHint": true]],
    ]

    // MARK: - Wire

    private static func json<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
