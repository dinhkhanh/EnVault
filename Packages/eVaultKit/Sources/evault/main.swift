import Foundation
import VaultCore
import EnvKit

// evault — command-line companion to the eVault app. Reads the same vault
// folder; the passphrase comes from EVAULT_PASSPHRASE or an interactive prompt.

let usage = """
usage: evault [--vault DIR] <command>

  ls                                  list projects and items
  get  <project> <item>               print an item's contents
  pull <project> <item> [-o PATH]     write an env file to disk (default: ./<item>)
  push <project> <item> <FILE>        create or update an item from a file
  run  <project> <item> -- CMD ...    run CMD with the env file's variables set
  history <project> <item>            list revisions
  init                                create a new vault in DIR

  unlock / lock                       cache the vault key in the login keychain (for hooks) / forget it
  link <project> <item> [DIR]         bind DIR (default: cwd) to an env file
  unlink [DIR]  ·  links              remove / list bindings
  env [--quiet] [--fish]              print `export` lines for the env file linked to cwd
  hook zsh|bash|fish                  print a shell hook that loads linked env files on cd
  deploy vercel <project> <item> [--target production|preview|development] [--dry-run]
  deploy cloudflare <project> <item> [--dry-run] [-- wrangler args]
  deploy github <project> <item> [--repo owner/name] [--dry-run] [-- gh args]
  example <project> <item>            print a .env.example for the file
  scan [DIR]                          look for leaked secrets in a source tree

Vault folder: --vault, $EVAULT_DIR, the iCloud Drive eVault folder, or the app's iCloud-synced vault
Passphrase:   $EVAULT_PASSPHRASE or a prompt.
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

/// Default vault: --vault / $EVAULT_DIR, else the iCloud Drive folder, else the
/// single iCloud-synced vault managed by the eVault app (in its container).
func defaultVaultDir() -> String {
    let drive = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/eVault"
    if FileManager.default.fileExists(atPath: drive + "/vault.json") { return drive }
    let appVaults = "\(home)/Library/Containers/dk.dinhkhanh.evault/Data/Library/Application Support/eVault/Vaults"
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: appVaults)) ?? []).filter { !$0.hasPrefix(".") }
    if ids.count == 1 { return appVaults + "/" + ids[0] }
    if ids.count > 1 { fail("several app vaults found; pass --vault DIR:\n" + ids.map { "  \(appVaults)/\($0)" }.joined(separator: "\n")) }
    return drive
}

let root = URL(fileURLWithPath: vaultDir ?? defaultVaultDir(), isDirectory: true)
guard let command = args.first else { fail(usage) }
args.removeFirst()

func passphrase() -> String {
    if let p = ProcessInfo.processInfo.environment["EVAULT_PASSPHRASE"], !p.isEmpty { return p }
    guard let c = getpass("Vault passphrase: ") else { fail("no passphrase") }
    return String(cString: c)
}

let quiet = args.contains("--quiet")

func openUnlocked() async throws -> VaultStore {
    let store = try await VaultStore.open(storage: LocalFolderStorage(root: root), device: DeviceIdentity(id: DeviceIdentity.current().id, name: DeviceIdentity.current().name + " (cli)"))
    if let cached = CLIKeyCache.load(vaultId: await store.vaultId) {
        try await store.unlock(vaultKey: cached)
    } else {
        if quiet { exit(0) } // hooks: never prompt
        try await store.unlock(passphrase: passphrase())
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
        if await store.projects().first(where: { $0.name == args[0] }) == nil {
            try await store.createProject(name: args[0])
            print("created project \(args[0])")
        }
        let (p, existing) = try await find(store, args[0], args[1])
        if let existing {
            try await store.updateItem(existing.id, payload: .envFile(text: text))
            print("updated \(args[0])/\(args[1])")
        } else {
            try await store.createItem(in: p.id, name: args[1], payload: .envFile(text: text))
            print("created \(args[0])/\(args[1])")
        }

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
        let vk = try await store.unlock(passphrase: passphrase())
        CLIKeyCache.save(vk, vaultId: await store.vaultId)
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

    case "scan":
        let dir = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath)
        let findings = EnvHygiene.scan(folder: dir)
        for f in findings { print("\(f.file):\(f.line): \(f.kind)  \(f.excerpt)") }
        print(findings.isEmpty ? "no secrets found" : "\(findings.count) finding(s)")
        exit(findings.isEmpty ? 0 : 2)

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
