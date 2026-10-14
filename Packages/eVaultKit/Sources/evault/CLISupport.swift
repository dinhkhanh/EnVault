import Foundation
import Security
import VaultCore
import EnvKit

// MARK: - Cached vault key for the CLI (`evault unlock` / `evault lock`)

/// The CLI caches the vault key in the login keychain so shell hooks don't
/// prompt on every `cd`. The app's Touch ID item is separate (and sandboxed).
enum CLIKeyCache {
    static let service = "dk.dinhkhanh.evault.cli-key"

    static func save(_ key: VaultKey, vaultId: UUID) {
        _ = SecItemDelete(query(vaultId) as CFDictionary)
        var q = query(vaultId)
        q[kSecValueData as String] = key.data
        q[kSecAttrLabel as String] = "eVault CLI cached vault key"
        _ = SecItemAdd(q as CFDictionary, nil)
    }

    static func load(vaultId: UUID) -> VaultKey? {
        var q = query(vaultId)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return VaultKey(data: d)
    }

    static func remove(vaultId: UUID) { _ = SecItemDelete(query(vaultId) as CFDictionary) }

    private static func query(_ vaultId: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: vaultId.uuidString]
    }
}

// MARK: - Links: directory → project/item

/// `~/.config/evault/links.json`: which env file belongs to which directory.
struct Link: Codable {
    var path: String
    var project: String
    var item: String
}

enum Links {
    static var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/evault/links.json")
    }

    static func load() -> [Link] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Link].self, from: d)) ?? []
    }

    static func save(_ links: [Link]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(links).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// The link whose path is the longest prefix of `dir`.
    static func match(_ dir: String) -> Link? {
        let d = URL(fileURLWithPath: dir).standardizedFileURL.path
        return load().filter { d == $0.path || d.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }
}

// MARK: - Shell hooks

enum ShellHook {
    /// Loads the linked env file's variables into the shell when entering a
    /// linked directory, and unloads them when leaving. Requires `evault unlock`.
    static func script(for shell: String) -> String? {
        switch shell {
        case "zsh", "bash":
            return """
            # eVault shell hook — add to your ~/.\(shell)rc:  eval "$(evault hook \(shell))"
            _evault_load() {
              local out
              if [ -n "$_EVAULT_KEYS" ]; then unset \(shell == "zsh" ? "${=_EVAULT_KEYS}" : "$_EVAULT_KEYS"); unset _EVAULT_KEYS; fi
              out="$(evault env --quiet 2>/dev/null)" || return 0
              [ -z "$out" ] && return 0
              eval "$out"
              _EVAULT_KEYS="$(printf '%s\\n' "$out" | sed -n 's/^export \\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' | tr '\\n' ' ')"
              export _EVAULT_KEYS
            }
            \(shell == "zsh" ? "autoload -U add-zsh-hook; add-zsh-hook chpwd _evault_load" : "PROMPT_COMMAND=\"_evault_load_once;${PROMPT_COMMAND}\"; _evault_load_once() { [ \"$PWD\" != \"$_EVAULT_PWD\" ] && { _EVAULT_PWD=\"$PWD\"; _evault_load; }; }")
            _evault_load
            """
        case "fish":
            return """
            # eVault shell hook — add to ~/.config/fish/config.fish:  evault hook fish | source
            function _evault_load --on-variable PWD
              if set -q _EVAULT_KEYS; for k in $_EVAULT_KEYS; set -e $k; end; set -e _EVAULT_KEYS; end
              set -l out (evault env --quiet --fish 2>/dev/null); or return
              test -z "$out"; and return
              for line in $out; eval $line; end
              set -gx _EVAULT_KEYS (printf '%s\\n' $out | string replace -r '^set -gx ([A-Za-z_][A-Za-z0-9_]*) .*' '$1')
            end
            _evault_load
            """
        default:
            return nil
        }
    }
}

// MARK: - Deploy targets (shell out to the vendors' own CLIs)

enum Deploy {
    static func run(_ exe: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [exe] + args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        if let stdin {
            let inp = Pipe(); p.standardInput = inp
            try p.run()
            inp.fileHandleForWriting.write(Data(stdin.utf8))
            try inp.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// `vercel env add KEY <target>` for each key, replacing existing values.
    static func vercel(doc: EnvDocument, target: String, dryRun: Bool) throws {
        for e in doc.entries {
            if dryRun { print("vercel env add \(e.key) \(target)"); continue }
            _ = try run("vercel", ["env", "rm", e.key, target, "--yes"])
            let r = try run("vercel", ["env", "add", e.key, target, "--force"], stdin: e.value)
            guard r.status == 0 else { throw CLIError("vercel env add \(e.key) failed:\n\(r.output)") }
            print("✓ \(e.key) → vercel \(target)")
        }
    }

    /// `wrangler secret bulk` with a temporary JSON file.
    static func cloudflare(doc: EnvDocument, extraArgs: [String], dryRun: Bool) throws {
        let json = try JSONSerialization.data(withJSONObject: doc.values, options: [.sortedKeys])
        if dryRun { print("wrangler secret bulk <\(doc.entries.count) keys> \(extraArgs.joined(separator: " "))"); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("evault-\(UUID().uuidString).json")
        try json.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try run("wrangler", ["secret", "bulk", tmp.path] + extraArgs)
        guard r.status == 0 else { throw CLIError("wrangler secret bulk failed:\n\(r.output)") }
        print("✓ \(doc.entries.count) secrets → cloudflare worker")
    }

    /// `gh secret set KEY` per key, for a repo (or `--env NAME`).
    static func github(doc: EnvDocument, repo: String?, extraArgs: [String], dryRun: Bool) throws {
        for e in doc.entries {
            var args = ["secret", "set", e.key]
            if let repo { args += ["--repo", repo] }
            args += extraArgs
            if dryRun { print("gh \(args.joined(separator: " "))"); continue }
            let r = try run("gh", args, stdin: e.value)
            guard r.status == 0 else { throw CLIError("gh secret set \(e.key) failed:\n\(r.output)") }
            print("✓ \(e.key) → github\(repo.map { " \($0)" } ?? "")")
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
