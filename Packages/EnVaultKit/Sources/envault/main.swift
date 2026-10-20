import Foundation
import VaultCore
import EnvKit

// envault — command-line companion to the EnVault app. Reads the same vault
// folder. The key comes from `envault unlock`'s cache, from the running app
// (approved with Touch ID), from ENVAULT_PASSPHRASE, or from a prompt.
//
// AI agents (detected from their environment, see AIAgents.detect) never get
// a prompt, have `run` output redacted, and need the user's approval in the
// app to read values. `envault mcp` serves the same as MCP tools.

let usage = """
usage: envault [--vault DIR] [--team NAME|ID] [--json] <command>

  ls                                  list projects and items
  keys <project> <item>               list an env file's variable names (no values)
  get  <project> <item>               print an item's contents
  pull <project> <item> [-o PATH]     write an env file to disk (default: ./<item>)
  push <project> <item> <FILE>        create or update an item from a file
  set  <project> <item> KEY=VALUE ... set variables (creates the env file if needed); KEY=- reads the value
       [--generate KEY]...            from stdin, --generate KEY stores a new random secret without printing it
  unset <project> <item> KEY ...      remove variables
  run  <project> <item> [--redact | --no-redact] -- CMD ...
                                      run CMD with the env file's variables set; --redact replaces secret
                                      values in its output with [redacted:KEY] (the default for AI agents)
  history <project> <item>            list revisions
  teams                               list the team vaults you belong to (use one with --team NAME)
  init                                create a new vault in DIR
  import <project> <item> <FILE|->    import a .env, JSON (Doppler, 1Password item) or .env.vault ($DOTENV_KEY) file
  import <project> <item> --doppler [-- doppler args]            from `doppler secrets download`
  import <project> <item> --1password <op item> [-- op args]     from `op item get`

  unlock [--passphrase]               cache the vault key in the login keychain (for hooks); asks EnVault for
                                      Touch ID approval when the app is running, else the passphrase
  lock                                forget the cached key
  link <project> <item> [DIR]         bind DIR (default: cwd) to an env file
  unlink [DIR]  ·  links              remove / list bindings
  env [--quiet] [--fish]              print `export` lines for the env file linked to cwd
  hook zsh|bash|fish                  print a shell hook that loads linked env files on cd
  deploy vercel <project> <item> [--target production|preview|development] [--dry-run]
  deploy cloudflare <project> <item> [--dry-run] [-- wrangler args]
  deploy github <project> <item> [--repo owner/name] [--dry-run] [-- gh args]
  example <project> <item>            print a .env.example for the file
  scan [DIR]                          look for leaked secrets in a source tree
  scan --staged                       scan what is about to be committed (used by the pre-commit hook)
  protect [DIR] [--remove]            install (or remove) a git pre-commit hook that runs `scan --staged`
  status                              is the EnVault app running, which vault, locked or not
  mcp                                 serve EnVault to AI agents over MCP (stdio)
  agent-guide [--skill]               print instructions for AI agents (for AGENTS.md / CLAUDE.md, or a skill)
  version                             print the version

Vault folder: --vault, $ENVAULT_DIR, the vault open in the EnVault app, the iCloud Drive EnVault folder,
              or the app's iCloud-synced vault.
Team vaults:  --team NAME|ID or $ENVAULT_TEAM works with every command that reads or changes items, and in
              `link`; they unlock with your personal vault (one approval) and are read through the EnVault app.
Key:          `envault unlock`'s cache, the running EnVault app (Touch ID), $ENVAULT_PASSPHRASE, or a prompt.
              Set ENVAULT_NO_APP=1 to never ask the app.
--json:       machine-readable output (ls, keys, status, history, links, scan, version, set, unset, push,
              import); errors become {"error", "code"} on stderr.
AI agents:    detected from CLAUDECODE, CURSOR_AGENT, GEMINI_CLI, CODEX_SANDBOX, or ENVAULT_AGENT=<name>
              (ENVAULT_AGENT=0: treat as a person). Agents never get a passphrase prompt, `run` redacts by
              default, and reading values (get, pull, env, run --no-redact, deploy) needs approval in EnVault.
Exit codes:   1 error, 2 scan found secrets, 3 not found, 4 needs the user (locked, approval),
              5 refused by the user or a setting, 64 usage
"""

var args = Array(CommandLine.arguments.dropFirst())

/// Removes a flag from the arguments before `--` (after it they belong to another command).
@MainActor
func takeFlag(_ name: String) -> Bool {
    let end = args.firstIndex(of: "--") ?? args.count
    guard let i = args[..<end].firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

@MainActor
func takeOption(_ name: String) -> String? {
    let end = args.firstIndex(of: "--") ?? args.count
    guard let i = args[..<end].firstIndex(of: name), i + 1 < end else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let env = ProcessInfo.processInfo.environment
let json = takeFlag("--json")
let quiet = takeFlag("--quiet")
let vaultDir = takeOption("--vault") ?? env["ENVAULT_DIR"]
let teamSelector = takeOption("--team") ?? env["ENVAULT_TEAM"].flatMap { $0.isEmpty ? nil : $0 }
let home = env["HOME"] ?? NSHomeDirectory()
let useApp = env["ENVAULT_NO_APP"].map { $0.isEmpty || $0 == "0" } ?? true
let aiAgent = AIAgents.detect(env)

func fail(_ msg: String, _ code: ExitCode = .error) -> Never {
    if json {
        let obj = ["error": msg, "code": code.name]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        FileHandle.standardError.write(data + Data("\n".utf8))
    } else {
        Out.stderr(msg)
    }
    exit(code.rawValue)
}

func usageError() -> Never { fail(usage, .usage) }

/// Prints `text` for people, or `value` as JSON with --json.
func output<T: Encodable>(_ text: @autoclosure () -> String, json value: @autoclosure () -> T) {
    if json { Out.json(value()) } else { print(text()) }
}

/// Default vault: --vault / $ENVAULT_DIR, else the vault the EnVault app has open
/// (starting it if needed), else the iCloud Drive folder, else the single
/// iCloud-synced vault managed by the EnVault app (in its container).
func defaultVaultDir(askApp: Bool) -> String {
    if askApp, useApp, let info = try? AgentClient()?.info(), let path = info.vaultPath { return path }
    // Not running: start it and use the vault it opens. Its iCloud-mode vault is
    // in its container, which this process may not be allowed to list, and an
    // older iCloud Drive vault must not win over the one the app uses.
    if askApp, useApp, let app = Session(root: URL(fileURLWithPath: "/"), agent: aiAgent, useApp: true, client: "envault",
                                         interactive: false).appAgent(launch: true) {
        for _ in 0..<50 {
            if let path = try? app.info().vaultPath { return path }
            usleep(200_000)
        }
    }
    let drive = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/EnVault"
    if FileManager.default.fileExists(atPath: drive + "/vault.json") { return drive }
    let appVaults = "\(home)/Library/Containers/dk.dinhkhanh.envault/Data/Library/Application Support/EnVault/Vaults"
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: appVaults)) ?? []).filter { !$0.hasPrefix(".") }
    if ids.count == 1 { return appVaults + "/" + ids[0] }
    if ids.count > 1 { fail("several app vaults found; pass --vault DIR:\n" + ids.map { "  \(appVaults)/\($0)" }.joined(separator: "\n")) }
    return drive
}

guard let command = args.first else { usageError() }
args.removeFirst()
/// Commands that never open a vault don't go looking for one.
let vaultless: Set<String> = ["scan", "protect", "version", "--version", "status", "hook", "links", "unlink", "help", "--help", "agent-guide"]
let root = URL(fileURLWithPath: vaultDir ?? (vaultless.contains(command) ? "" : defaultVaultDir(askApp: command != "init")), isDirectory: true)

let session = Session(root: root, agent: aiAgent, useApp: useApp, client: "envault \(command)",
                      interactive: aiAgent == nil, cachedOnly: quiet, team: teamSelector)

// JSON shapes
struct ItemJSON: Encodable { var name: String; var kind: String; var revisions: Int }
struct ProjectJSON: Encodable { var name: String; var items: [ItemJSON] }
struct KeyJSON: Encodable { var name: String; var empty: Bool; var redacted: Bool }
struct KeysJSON: Encodable { var project: String; var item: String; var keys: [KeyJSON] }
struct RevisionJSON: Encodable { var id: String; var modifiedAt: Date; var device: String; var deleted: Bool }
struct TeamJSON: Encodable { var id: String; var name: String?; var role: String?; var access: String }
struct FindingJSON: Encodable { var file: String; var line: Int; var kind: String; var excerpt: String }
struct ScanJSON: Encodable { var findings: [FindingJSON] }
struct ResultJSON: Encodable { var ok = true; var message: String; var keys: [String]? = nil }
struct StatusJSON: Encodable {
    var appRunning: Bool
    var appVersion: String?
    var vault: String?
    var mode: String?
    var locked: Bool?
    var cliKeyCached: Bool
    var agent: String?
    var agentPolicy: AIAgents.Policy?
}

func findingsJSON(_ f: [EnvHygiene.Finding]) -> ScanJSON {
    ScanJSON(findings: f.map { FindingJSON(file: $0.file, line: $0.line, kind: $0.kind, excerpt: $0.excerpt) })
}

/// Agents can't answer prompts or should leave some things to the user.
func refuseForAgent(_ why: String) {
    guard let aiAgent else { return }
    fail("\(aiAgent) is running envault: \(why)", .denied)
}

do {
    switch command {
    case "init":
        refuseForAgent("creating a vault needs the user (ask them to run `envault init` or use the app)")
        let pass = try Session.envPassphrase ?? Session.promptPassphrase()
        _ = try await VaultStore.create(storage: LocalFolderStorage(root: root), passphrase: pass)
        print("created vault at \(root.path)")

    case "ls":
        let store = try await session.content(.use)
        var projects: [ProjectJSON] = []
        for p in await store.projects(includeDeleted: false) {
            projects.append(ProjectJSON(name: p.name, items: await store.items(in: p.id).map {
                ItemJSON(name: $0.name, kind: $0.kind.rawValue, revisions: $0.revisionCount)
            }))
        }
        output(projects.map { p in ([p.name] + p.items.map { "  \($0.name)  [\(ItemKind(rawValue: $0.kind))]  \($0.revisions) rev" }).joined(separator: "\n") }
                .joined(separator: "\n"), json: projects)

    case "keys":
        guard args.count == 2 else { usageError() }
        let store = try await session.content(.use, "\(args[0])/\(args[1])")
        let doc = try envDoc(try await find(store, args[0], args[1]))
        let keys = doc.entries.map { KeyJSON(name: $0.key, empty: $0.value.isEmpty, redacted: EnvRedactor.redacts($0)) }
        output(keys.map(\.name).joined(separator: "\n"), json: KeysJSON(project: args[0], item: args[1], keys: keys))

    case "get":
        guard args.count == 2 else { usageError() }
        let store = try await session.content(.reveal, "\(args[0])/\(args[1])")
        let item = try await find(store, args[0], args[1])
        FileHandle.standardOutput.write(Data(item.payload.primaryText.utf8))

    case "pull":
        guard args.count >= 2 else { usageError() }
        let out = takeOption("-o") ?? args[1]
        let store = try await session.content(.reveal, "\(args[0])/\(args[1])")
        let item = try await find(store, args[0], args[1])
        try item.payload.primaryText.write(toFile: out, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out)
        output("wrote \(out)", json: ResultJSON(message: "wrote \(out)"))

    case "push":
        guard args.count == 3 else { usageError() }
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        let store = try await session.content(.write, "\(args[0])/\(args[1])")
        let msg = try await upsert(store, project: args[0], item: args[1], text: text)
        output(msg, json: ResultJSON(message: msg))

    case "set":
        var generate: [String] = []
        while let k = takeOption("--generate") { generate.append(k) }
        guard args.count >= 2, args.count > 2 || !generate.isEmpty else { usageError() }
        var pairs: [(key: String, value: String)] = []
        var readStdin = false
        for a in args.dropFirst(2) {
            guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { fail("expected KEY=VALUE, got \(a)", .usage) }
            var value = String(a[a.index(after: eq)...])
            if value == "-" {
                guard !readStdin else { fail("only one KEY=- can read stdin", .usage) }
                readStdin = true
                value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                if value.hasSuffix("\n") { value.removeLast() }
            }
            pairs.append((String(a[..<eq]), value))
        }
        pairs += generate.map { ($0, generateSecret()) }
        let store = try await session.content(.write, "\(args[0])/\(args[1])")
        let msg = try await editEnv(store, project: args[0], item: args[1], set: pairs, unset: [])
        let names = pairs.map(\.key)
        let text = msg + (generate.isEmpty ? "" : "\ngenerated \(generate.joined(separator: ", ")) (32 random bytes, base64url)")
        output(text, json: ResultJSON(message: msg, keys: names))

    case "unset":
        guard args.count >= 3 else { usageError() }
        let store = try await session.content(.write, "\(args[0])/\(args[1])")
        let msg = try await editEnv(store, project: args[0], item: args[1], set: [], unset: Array(args.dropFirst(2)))
        output(msg, json: ResultJSON(message: msg, keys: Array(args.dropFirst(2))))

    case "import":
        guard args.count >= 3 else { usageError() }
        let (project, itemName) = (args[0], args[1])
        let dash = args.firstIndex(of: "--")
        let extra = dash.map { Array(args[($0 + 1)...]) } ?? []
        let opts = Array(args[2..<(dash ?? args.count)])
        let text: String
        if opts.first == "--doppler" {
            let r = try Deploy.run("doppler", ["secrets", "download", "--no-file", "--format", "env"] + extra, mergeStderr: false)
            guard r.status == 0 else { fail("doppler failed (is it installed and logged in? `doppler login`, `doppler setup`)") }
            text = r.output
        } else if opts.first == "--1password" {
            guard opts.count >= 2 else { fail("usage: envault import <project> <item> --1password <op item> [-- op args]", .usage) }
            let r = try Deploy.run("op", ["item", "get", opts[1], "--format", "json"] + extra, mergeStderr: false)
            guard r.status == 0 else { fail("op failed (is the 1Password CLI installed and signed in?)") }
            text = try EnvImport.dotenv(fromJSON: r.output)
        } else {
            let path = opts[0]
            let raw = path == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : try String(contentsOfFile: path, encoding: .utf8)
            switch EnvImport.detect(text: raw, fileName: (path as NSString).lastPathComponent) {
            case .dotenv: text = raw
            case .json: text = try EnvImport.dotenv(fromJSON: raw)
            case .dotenvVault:
                guard let keys = env["DOTENV_KEY"], let first = keys.split(separator: ",").first else {
                    fail("set DOTENV_KEY to decrypt it (environments in the file: \(EnvImport.vaultEnvironments(raw).joined(separator: ", ")))")
                }
                text = try EnvImport.decryptVault(raw, key: EnvImport.parseDotenvKey(String(first)))
            }
        }
        let n = DotEnv.parse(text).entries.count
        let store = try await session.content(.write, "\(project)/\(itemName)")
        let msg = try await upsert(store, project: project, item: itemName, text: text)
        output("\(msg)\n\(n) key\(n == 1 ? "" : "s")", json: ResultJSON(message: msg, keys: DotEnv.parse(text).entries.map(\.key)))

    case "run":
        let redactFlag = takeFlag("--redact"), noRedact = takeFlag("--no-redact")
        let redact = redactFlag || (aiAgent != nil && !noRedact)
        guard let dash = args.firstIndex(of: "--"), dash == 2, args.count > 3 else { usageError() }
        let store = try await session.content(redact || aiAgent == nil ? .use : .reveal, "\(args[0])/\(args[1])")
        let doc = try envDoc(try await find(store, args[0], args[1]))
        var childEnv = env
        for (k, v) in doc.values { childEnv[k] = v }
        let argv = Array(args[(dash + 1)...])
        if redact {
            let result = try Runner.run(argv, env: childEnv, redact: doc,
                                        stdout: { FileHandle.standardOutput.write($0) },
                                        stderr: { FileHandle.standardError.write($0) })
            exit(result.status)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        proc.environment = childEnv
        try proc.run()
        proc.waitUntilExit()
        exit(proc.terminationStatus)

    case "history":
        guard args.count == 2 else { usageError() }
        let store = try await session.content(.use, "\(args[0])/\(args[1])")
        let item = try await find(store, args[0], args[1])
        let revs = await store.history(of: item.id)
        let f = ISO8601DateFormatter()
        output(revs.map { "\($0.id)  \(f.string(from: $0.modifiedAt))  \($0.device.name)\($0.deleted ? "  [deleted]" : "")" }.joined(separator: "\n"),
               json: revs.map { RevisionJSON(id: "\($0.id)", modifiedAt: $0.modifiedAt, device: $0.device.name, deleted: $0.deleted) })

    case "teams":
        let teams = try await session.teamVaults(.use, "the list of team vaults")
        func describe(_ a: TeamAccess) -> (role: String?, access: String) {
            switch a {
            case .member(let r): (r.rawValue, "member")
            case .awaitingKey(let r): (r.rawValue, "waiting for the key")
            case .notMember: (nil, "waiting for approval")
            case .removed: (nil, "removed")
            case .locked: (nil, "locked")
            }
        }
        let rows = teams.map { t in TeamJSON(id: t.id.uuidString, name: t.title, role: describe(t.access).role, access: describe(t.access).access) }
        output(rows.isEmpty ? "no team vaults" : rows.map { "\($0.name ?? "untitled")  \($0.id.prefix(8))  \($0.role ?? $0.access)" }.joined(separator: "\n"), json: rows)

    case "unlock":
        refuseForAgent("`envault unlock` caches the vault key for every later command; ask the user to run it in their own terminal")
        let store = try await session.open()
        let vaultId = await store.vaultId
        var vk: VaultKey?
        if !args.contains("--passphrase"), Session.envPassphrase == nil,
           let k = session.keyFromApp(vaultId: vaultId), (try? await store.unlock(vaultKey: k)) != nil {
            vk = k
        }
        if vk == nil { vk = try await store.unlock(passphrase: Session.envPassphrase ?? Session.promptPassphrase()) }
        CLIKeyCache.save(vk!, vaultId: vaultId)
        print("vault key cached in the login keychain; run `envault lock` to forget it")

    case "lock":
        let store = try await session.open()
        CLIKeyCache.remove(vaultId: await store.vaultId)
        print("forgotten")

    case "link":
        guard args.count >= 2 else { usageError() }
        let dir = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let store = try await session.content(.use, "\(args[0])/\(args[1])")
        _ = try await find(store, args[0], args[1])
        var links = Links.load().filter { $0.path != dir }
        links.append(Link(path: dir, project: args[0], item: args[1], team: teamSelector))
        try Links.save(links)
        print("linked \(dir) → \(teamSelector.map { "\($0) › " } ?? "")\(args[0])/\(args[1])")

    case "unlink":
        let dir = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
        try Links.save(Links.load().filter { $0.path != dir })
        print("unlinked \(dir)")

    case "links":
        let links = Links.load().sorted(by: { $0.path < $1.path })
        output(links.map { "\($0.path)  →  \($0.team.map { "\($0) › " } ?? "")\($0.project)/\($0.item)" }.joined(separator: "\n"), json: links)

    case "env":
        // Shell hooks in an agent's shell stay silent: agents use `envault run`.
        if quiet, aiAgent != nil { exit(0) }
        guard let link = Links.match(FileManager.default.currentDirectoryPath) else { if quiet { exit(0) } else { fail("no env file linked to this directory; run `envault link <project> <item>`", .notFound) } }
        var linked = session
        linked.team = link.team
        let store: any VaultContent
        do { store = try await linked.content(.reveal, "\(link.project)/\(link.item)") } catch let e as CLIError where quiet && e.code == .needsUser { exit(0) }
        guard let item = try? await find(store, link.project, link.item) else { if quiet { exit(0) } else { fail("linked item \(link.item) no longer exists", .notFound) } }
        let doc = try envDoc(item)
        if args.contains("--fish") {
            for e in doc.entries { print("set -gx \(e.key) \(EnvExport.shellQuote(e.value))") }
        } else {
            FileHandle.standardOutput.write(Data(EnvExport.shell(doc).utf8))
        }

    case "hook":
        guard let shell = args.first, let script = ShellHook.script(for: shell) else { fail("usage: envault hook zsh|bash|fish", .usage) }
        print(script)

    case "deploy":
        guard args.count >= 3 else { usageError() }
        let target = args[0]
        let dash = args.firstIndex(of: "--")
        let extra = dash.map { Array(args[($0 + 1)...]) } ?? []
        let dry = args.contains("--dry-run")
        let store = try await session.content(dry ? .use : .reveal, "\(args[1])/\(args[2]) to \(target)")
        let doc = try envDoc(try await find(store, args[1], args[2]))
        switch target {
        case "vercel":
            let t = args.firstIndex(of: "--target").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "production"
            try Deploy.vercel(doc: doc, target: t, dryRun: dry)
        case "cloudflare":
            try Deploy.cloudflare(doc: doc, extraArgs: extra, dryRun: dry)
        case "github":
            let repo = args.firstIndex(of: "--repo").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            try Deploy.github(doc: doc, repo: repo, extraArgs: extra, dryRun: dry)
        default:
            fail("unknown deploy target \(target); use vercel, cloudflare or github", .usage)
        }

    case "example":
        guard args.count == 2 else { usageError() }
        let store = try await session.content(.use, "\(args[0])/\(args[1])")
        FileHandle.standardOutput.write(Data(EnvHygiene.example(from: try envDoc(try await find(store, args[0], args[1]))).utf8))

    case "scan" where args.contains("--staged"):
        let findings = try StagedScan.run()
        for f in findings { Out.stderr("\(f.file):\(f.line): \(f.kind)  \(f.excerpt)") }
        if !findings.isEmpty {
            fail("""
            EnVault blocked this commit: \(findings.count) possible secret\(findings.count == 1 ? "" : "s").
            Move real secrets into EnVault (`envault push`), add `envault:allow` to a line that is a false positive,
            or commit with --no-verify to skip the check once.
            """)
        }

    case "protect":
        let dir = args.first { !$0.hasPrefix("-") } ?? FileManager.default.currentDirectoryPath
        let hooks = try StagedScan.hooksDir(repo: dir)
        if args.contains("--remove") {
            try GitHook.uninstall(hooksDir: hooks)
            print("removed the EnVault pre-commit check from \(hooks.path)")
        } else {
            let url = try GitHook.install(hooksDir: hooks)
            print("installed \(url.path): commits are scanned for secrets")
        }

    case "version", "--version":
        output("envault \(envaultVersion)", json: ["version": envaultVersion])

    case "status":
        let agent = useApp ? AgentClient() : nil
        let info = try agent?.info()
        let cached = info?.vaultId.map { CLIKeyCache.load(vaultId: $0) != nil } ?? false
        if json {
            Out.json(StatusJSON(appRunning: info != nil, appVersion: info?.appVersion, vault: info?.vaultPath, mode: info?.mode,
                                locked: info?.locked, cliKeyCached: cached, agent: aiAgent, agentPolicy: info?.agents))
            break
        }
        guard useApp else { print("ENVAULT_NO_APP is set: not asking the EnVault app"); break }
        guard let i = info else { print("EnVault is not running (or is older than 0.4); envault will ask for the passphrase"); break }
        print("EnVault \(i.appVersion) is running")
        if let path = i.vaultPath {
            print("vault:  \(path)\(i.mode == "icloud" ? "  (iCloud)" : "")")
            print("state:  \(i.locked ? "locked (Touch ID approval still works if Touch ID unlock is on)" : "unlocked")")
        } else {
            print("vault:  none open")
        }
        print("cli:    \(cached ? "key cached by `envault unlock`" : "no cached key; commands ask EnVault (Touch ID)")")
        if let aiAgent { print("agent:  \(aiAgent) (output of `envault run` is redacted; reading values needs approval)") }
        if let p = i.agents {
            print("agents: \(p.enabled ? "allowed" : "turned off"); values: \(p.values.rawValue); changes: \(p.writes ? "allowed" : "not allowed")")
        }

    case "scan":
        let dir = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath)
        let findings = EnvHygiene.scan(folder: dir)
        output(findings.map { "\($0.file):\($0.line): \($0.kind)  \($0.excerpt)" }.joined(separator: "\n")
                + (findings.isEmpty ? "no secrets found" : "\n\(findings.count) finding(s)"), json: findingsJSON(findings))
        exit(findings.isEmpty ? 0 : ExitCode.findings.rawValue)

    case "mcp":
        await MCPServer(session: session).run()

    case "agent-guide":
        print(args.contains("--skill") ? AIAgents.skill : AIAgents.guide)

    case "help", "--help":
        print(usage)

    default:
        usageError()
    }
} catch {
    let e = CLIError.from(error)
    fail(json ? e.description : "error: \(e.description)", e.code)
}
