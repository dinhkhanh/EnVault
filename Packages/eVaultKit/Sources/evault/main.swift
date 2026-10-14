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

Vault folder: --vault, $EVAULT_DIR, or ~/Library/Mobile Documents/com~apple~CloudDocs/eVault
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
let root = URL(fileURLWithPath: vaultDir ?? "\(home)/Library/Mobile Documents/com~apple~CloudDocs/eVault", isDirectory: true)
guard let command = args.first else { fail(usage) }
args.removeFirst()

func passphrase() -> String {
    if let p = ProcessInfo.processInfo.environment["EVAULT_PASSPHRASE"], !p.isEmpty { return p }
    guard let c = getpass("Vault passphrase: ") else { fail("no passphrase") }
    return String(cString: c)
}

func openUnlocked() async throws -> VaultStore {
    let store = try await VaultStore.open(storage: LocalFolderStorage(root: root), device: DeviceIdentity(id: DeviceIdentity.current().id, name: DeviceIdentity.current().name + " (cli)"))
    try await store.unlock(passphrase: passphrase())
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

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
