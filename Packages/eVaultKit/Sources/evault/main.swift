import Foundation
import VaultCore
import EnvKit

// evault — command-line companion to the eVault app. Reads the same vault
// folder. The key comes from `evault unlock`'s cache, from the running app
// (approved with Touch ID), from EVAULT_PASSPHRASE, or from a prompt.

let usage = """
usage: evault [--vault DIR] <command>

  ls                                  list projects and items
  get  <project> <item>               print an item's contents
  pull <project> <item> [-o PATH]     write an env file to disk (default: ./<item>)
  push <project> <item> <FILE>        create or update an item from a file
  run  <project> <item> -- CMD ...    run CMD with the env file's variables set
  history <project> <item>            list revisions
  init                                create a new vault in DIR
  import <project> <item> <FILE|->    import a .env, JSON (Doppler, 1Password item) or .env.vault ($DOTENV_KEY) file
  import <project> <item> --doppler [-- doppler args]            from `doppler secrets download`
  import <project> <item> --1password <op item> [-- op args]     from `op item get`

  unlock [--passphrase]               cache the vault key in the login keychain (for hooks); asks eVault for
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
  status                              is the eVault app running, which vault, locked or not
  version                             print the version

Vault folder: --vault, $EVAULT_DIR, the vault open in the eVault app, the iCloud Drive eVault folder,
              or the app's iCloud-synced vault.
Key:          `evault unlock`'s cache, the running eVault app (Touch ID), $EVAULT_PASSPHRASE, or a prompt.
              Set EVAULT_NO_APP=1 to never ask the app.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var vaultDir: String? = ProcessInfo.processInfo.environment["EVAULT_DIR"]
if let i = args.firstIndex(of: "--vault"), i + 1 < args.count {
    vaultDir = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

let useApp = ProcessInfo.processInfo.environment["EVAULT_NO_APP"].map { $0.isEmpty || $0 == "0" } ?? true

/// Default vault: --vault / $EVAULT_DIR, else the vault the running app has
/// open, else the iCloud Drive folder, else the single iCloud-synced vault
/// managed by the eVault app (in its container).
func defaultVaultDir(askApp: Bool) -> String {
    if askApp, useApp, let info = try? AgentClient()?.info(), let path = info.vaultPath { return path }
    let drive = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/eVault"
    if FileManager.default.fileExists(atPath: drive + "/vault.json") { return drive }
    let appVaults = "\(home)/Library/Containers/dk.dinhkhanh.evault/Data/Library/Application Support/eVault/Vaults"
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: appVaults)) ?? []).filter { !$0.hasPrefix(".") }
    if ids.count == 1 { return appVaults + "/" + ids[0] }
    if ids.count > 1 { fail("several app vaults found; pass --vault DIR:\n" + ids.map { "  \(appVaults)/\($0)" }.joined(separator: "\n")) }
    return drive
}

guard let command = args.first else { fail(usage) }
args.removeFirst()
/// Commands that never open a vault don't go looking for one.
let vaultless: Set<String> = ["scan", "protect", "version", "--version", "status", "hook", "links", "unlink", "help", "--help"]
let root = URL(fileURLWithPath: vaultDir ?? (vaultless.contains(command) ? "" : defaultVaultDir(askApp: command != "init")), isDirectory: true)

/// The eVault app's agent, launching the app in the background if needed.
func appAgent(launch: Bool) -> AgentClient? {
    guard useApp else { return nil }
    if let c = AgentClient() { return c }
    guard launch else { return nil }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-j", "-b", "dk.dinhkhanh.evault"]
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

/// Asks the app for the key (Touch ID prompt in eVault). Nil if the app isn't
/// available; prints why it refused otherwise.
func keyFromApp(vaultId: UUID) -> VaultKey? {
    guard let agent = appAgent(launch: true) else { return nil }
    FileHandle.standardError.write(Data("Approve in eVault (Touch ID)…\n".utf8))
    do {
        return try agent.requestKey(vaultId: vaultId, client: "evault \(command)")
    } catch {
        FileHandle.standardError.write(Data("eVault: \(error.localizedDescription)\n".utf8))
        return nil
    }
}

func passphrase() -> String {
    if let p = ProcessInfo.processInfo.environment["EVAULT_PASSPHRASE"], !p.isEmpty { return p }
    guard let c = getpass("Vault passphrase: ") else { fail("no passphrase") }
    return String(cString: c)
}

let quiet = args.contains("--quiet")

func openUnlocked() async throws -> VaultStore {
    let store = try await VaultStore.open(storage: LocalFolderStorage(root: root), device: DeviceIdentity(id: DeviceIdentity.current().id, name: DeviceIdentity.current().name + " (cli)"))
    let vaultId = await store.vaultId
    if let cached = CLIKeyCache.load(vaultId: vaultId) {
        try await store.unlock(vaultKey: cached)
    } else {
        if quiet { exit(0) } // hooks: never prompt
        if ProcessInfo.processInfo.environment["EVAULT_PASSPHRASE"]?.isEmpty == false {
            try await store.unlock(passphrase: passphrase())
        } else if let key = keyFromApp(vaultId: vaultId), (try? await store.unlock(vaultKey: key)) != nil {
            // unlocked through the app
        } else {
            try await store.unlock(passphrase: passphrase())
        }
    }
    return store
}

func find(_ store: VaultStore, _ projectName: String, _ itemName: String) async throws -> (Project, Item?) {
    guard let p = await store.projects().first(where: { $0.name == projectName }) else { fail("no project named \(projectName)") }
    let item = await store.items(in: p.id).first { $0.name == itemName }
    return (p, item)
}

func envDoc(_ item: Item) -> EnvDocument {
    guard case .envFile(let text) = item.payload else { fail("\(item.name) is not an env file") }
    return DotEnv.parse(text)
}

do {
    switch command {
    case "init":
        _ = try await VaultStore.create(storage: LocalFolderStorage(root: root), passphrase: passphrase())
        print("created vault at \(root.path)")

    case "ls":
        let store = try await openUnlocked()
        for p in await store.projects() {
            print(p.name)
            for i in await store.items(in: p.id) {
                print("  \(i.name)  [\(i.kind)]  \(i.revisionCount) rev")
            }
        }

    case "get":
        guard args.count == 2 else { fail(usage) }
        let store = try await openUnlocked()
        guard let item = try await find(store, args[0], args[1]).1 else { fail("no item named \(args[1])") }
        FileHandle.standardOutput.write(Data(item.payload.primaryText.utf8))

    case "pull":
        guard args.count >= 2 else { fail(usage) }
        var out = args[1]
        if let i = args.firstIndex(of: "-o"), i + 1 < args.count { out = args[i + 1] }
        let store = try await openUnlocked()
        guard let item = try await find(store, args[0], args[1]).1 else { fail("no item named \(args[1])") }
        try item.payload.primaryText.write(toFile: out, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out)
        print("wrote \(out)")

    case "push":
        guard args.count == 3 else { fail(usage) }
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        let store = try await openUnlocked()
        try await upsert(store, project: args[0], item: args[1], text: text)

    case "import":
        guard args.count >= 3 else { fail(usage) }
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
            guard opts.count >= 2 else { fail("usage: evault import <project> <item> --1password <op item> [-- op args]") }
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
                guard let keys = ProcessInfo.processInfo.environment["DOTENV_KEY"], let first = keys.split(separator: ",").first else {
                    fail("set DOTENV_KEY to decrypt it (environments in the file: \(EnvImport.vaultEnvironments(raw).joined(separator: ", ")))")
                }
                text = try EnvImport.decryptVault(raw, key: EnvImport.parseDotenvKey(String(first)))
            }
        }
        let n = DotEnv.parse(text).entries.count
        let store = try await openUnlocked()
        try await upsert(store, project: project, item: itemName, text: text)
        print("\(n) key\(n == 1 ? "" : "s")")

    case "run":
        guard let dash = args.firstIndex(of: "--"), dash == 2, args.count > 3 else { fail(usage) }
        let store = try await openUnlocked()
        guard let item = try await find(store, args[0], args[1]).1 else { fail("no item named \(args[1])") }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in envDoc(item).values { env[k] = v }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = Array(args[(dash + 1)...])
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        exit(proc.terminationStatus)

    case "history":
        guard args.count == 2 else { fail(usage) }
        let store = try await openUnlocked()
        guard let item = try await find(store, args[0], args[1]).1 else { fail("no item named \(args[1])") }
        let f = ISO8601DateFormatter()
        for r in await store.history(of: item.id) {
            print("\(r.id)  \(f.string(from: r.modifiedAt))  \(r.device.name)\(r.deleted ? "  [deleted]" : "")")
        }

    case "unlock":
        let store = try await VaultStore.open(storage: LocalFolderStorage(root: root))
        let vaultId = await store.vaultId
        var vk: VaultKey?
        if !args.contains("--passphrase"), ProcessInfo.processInfo.environment["EVAULT_PASSPHRASE"]?.isEmpty != false,
           let k = keyFromApp(vaultId: vaultId), (try? await store.unlock(vaultKey: k)) != nil {
            vk = k
        }
        if vk == nil { vk = try await store.unlock(passphrase: passphrase()) }
        CLIKeyCache.save(vk!, vaultId: vaultId)
        print("vault key cached in the login keychain; run `evault lock` to forget it")

    case "lock":
        let store = try await VaultStore.open(storage: LocalFolderStorage(root: root))
        CLIKeyCache.remove(vaultId: await store.vaultId)
        print("forgotten")

    case "link":
        guard args.count >= 2 else { fail(usage) }
        let dir = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let store = try await openUnlocked()
        guard try await find(store, args[0], args[1]).1 != nil else { fail("no item named \(args[1]) in \(args[0])") }
        var links = Links.load().filter { $0.path != dir }
        links.append(Link(path: dir, project: args[0], item: args[1]))
        try Links.save(links)
        print("linked \(dir) → \(args[0])/\(args[1])")

    case "unlink":
        let dir = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
        try Links.save(Links.load().filter { $0.path != dir })
        print("unlinked \(dir)")

    case "links":
        for l in Links.load().sorted(by: { $0.path < $1.path }) { print("\(l.path)  →  \(l.project)/\(l.item)") }

    case "env":
        guard let link = Links.match(FileManager.default.currentDirectoryPath) else { if quiet { exit(0) } else { fail("no env file linked to this directory; run `evault link <project> <item>`") } }
        let store = try await openUnlocked()
        guard let item = try await find(store, link.project, link.item).1 else { if quiet { exit(0) } else { fail("linked item \(link.item) no longer exists") } }
        let doc = envDoc(item)
        if args.contains("--fish") {
            for e in doc.entries { print("set -gx \(e.key) \(EnvExport.shellQuote(e.value))") }
        } else {
            FileHandle.standardOutput.write(Data(EnvExport.shell(doc).utf8))
        }

    case "hook":
        guard let shell = args.first, let script = ShellHook.script(for: shell) else { fail("usage: evault hook zsh|bash|fish") }
        print(script)

    case "deploy":
        guard args.count >= 3 else { fail(usage) }
        let target = args[0]
        let dash = args.firstIndex(of: "--")
        let extra = dash.map { Array(args[($0 + 1)...]) } ?? []
        let dry = args.contains("--dry-run")
        let store = try await openUnlocked()
        guard let item = try await find(store, args[1], args[2]).1 else { fail("no item named \(args[2])") }
        let doc = envDoc(item)
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
            fail("unknown deploy target \(target); use vercel, cloudflare or github")
        }

    case "example":
        guard args.count == 2 else { fail(usage) }
        let store = try await openUnlocked()
        guard let item = try await find(store, args[0], args[1]).1 else { fail("no item named \(args[1])") }
        FileHandle.standardOutput.write(Data(EnvHygiene.example(from: envDoc(item)).utf8))

    case "scan" where args.contains("--staged"):
        let findings = try StagedScan.run()
        for f in findings { FileHandle.standardError.write(Data("\(f.file):\(f.line): \(f.kind)  \(f.excerpt)\n".utf8)) }
        if !findings.isEmpty {
            fail("""
            eVault blocked this commit: \(findings.count) possible secret\(findings.count == 1 ? "" : "s").
            Move real secrets into eVault (`evault push`), add `evault:allow` to a line that is a false positive,
            or commit with --no-verify to skip the check once.
            """)
        }

    case "protect":
        let dir = args.first { !$0.hasPrefix("-") } ?? FileManager.default.currentDirectoryPath
        let hooks = try StagedScan.hooksDir(repo: dir)
        if args.contains("--remove") {
            try GitHook.uninstall(hooksDir: hooks)
            print("removed the eVault pre-commit check from \(hooks.path)")
        } else {
            let url = try GitHook.install(hooksDir: hooks)
            print("installed \(url.path): commits are scanned for secrets")
        }

    case "version", "--version":
        print("evault \(evaultVersion)")

    case "status":
        guard useApp else { print("EVAULT_NO_APP is set: not asking the eVault app"); break }
        guard let agent = AgentClient() else { print("eVault is not running (or is older than 0.4); evault will ask for the passphrase"); break }
        let i = try agent.info()
        print("eVault \(i.appVersion) is running")
        if let path = i.vaultPath {
            print("vault:  \(path)\(i.mode == "icloud" ? "  (iCloud)" : "")")
            print("state:  \(i.locked ? "locked (Touch ID approval still works if Touch ID unlock is on)" : "unlocked")")
        } else {
            print("vault:  none open")
        }
        let cached = i.vaultId.map { CLIKeyCache.load(vaultId: $0) != nil } ?? false
        print("cli:    \(cached ? "key cached by `evault unlock`" : "no cached key; commands ask eVault (Touch ID)")")

    case "scan":
        let dir = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath)
        let findings = EnvHygiene.scan(folder: dir)
        for f in findings { print("\(f.file):\(f.line): \(f.kind)  \(f.excerpt)") }
        print(findings.isEmpty ? "no secrets found" : "\(findings.count) finding(s)")
        exit(findings.isEmpty ? 0 : 2)

    case "help", "--help":
        print(usage)

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
