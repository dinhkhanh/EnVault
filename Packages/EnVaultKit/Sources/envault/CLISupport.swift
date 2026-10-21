import Foundation
import Security
import VaultCore
import EnvKit

// MARK: - Cached vault key for the CLI (`envault unlock` / `envault lock`)

/// The CLI caches the vault key in the login keychain so shell hooks don't
/// prompt on every `cd`. The app's Touch ID item is separate (and sandboxed).
enum CLIKeyCache {
    static let service = "dk.dinhkhanh.envault.cli-key"

    static func save(_ key: VaultKey, vaultId: UUID) {
        _ = SecItemDelete(query(vaultId) as CFDictionary)
        var q = query(vaultId)
        q[kSecValueData as String] = key.data
        q[kSecAttrLabel as String] = "EnVault CLI cached vault key"
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

/// `~/.config/envault/links.json`: which env file belongs to which directory.
struct Link: Codable {
    var path: String
    var project: String
    var item: String
    /// The team vault (`--team`), nil for the personal vault.
    var team: String?
}

enum Links {
    static var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".config/envault/links.json")
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
    /// linked directory, and unloads them when leaving. Requires `envault unlock`.
    static func script(for shell: String) -> String? {
        switch shell {
        case "zsh", "bash":
            return """
            # EnVault shell hook — add to your ~/.\(shell)rc:  eval "$(envault hook \(shell))"
            _envault_load() {
              local out
              if [ -n "$_ENVAULT_KEYS" ]; then unset \(shell == "zsh" ? "${=_ENVAULT_KEYS}" : "$_ENVAULT_KEYS"); unset _ENVAULT_KEYS; fi
              out="$(envault env --quiet 2>/dev/null)" || return 0
              [ -z "$out" ] && return 0
              eval "$out"
              _ENVAULT_KEYS="$(printf '%s\\n' "$out" | sed -n 's/^export \\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' | tr '\\n' ' ')"
              export _ENVAULT_KEYS
            }
            \(shell == "zsh" ? "autoload -U add-zsh-hook; add-zsh-hook chpwd _envault_load" : "PROMPT_COMMAND=\"_envault_load_once;${PROMPT_COMMAND}\"; _envault_load_once() { [ \"$PWD\" != \"$_ENVAULT_PWD\" ] && { _ENVAULT_PWD=\"$PWD\"; _envault_load; }; }")
            _envault_load
            """
        case "fish":
            return """
            # EnVault shell hook — add to ~/.config/fish/config.fish:  envault hook fish | source
            function _envault_load --on-variable PWD
              if set -q _ENVAULT_KEYS; for k in $_ENVAULT_KEYS; set -e $k; end; set -e _ENVAULT_KEYS; end
              set -l out (envault env --quiet --fish 2>/dev/null); or return
              test -z "$out"; and return
              for line in $out; eval $line; end
              set -gx _ENVAULT_KEYS (printf '%s\\n' $out | string replace -r '^set -gx ([A-Za-z_][A-Za-z0-9_]*) .*' '$1')
            end
            _envault_load
            """
        default:
            return nil
        }
    }
}

// MARK: - Deploy targets (shell out to the vendors' own CLIs)

enum Deploy {
    /// Runs `exe` from PATH. With `mergeStderr: false`, stderr goes to the terminal
    /// (so sign-in prompts stay visible) and only stdout is captured.
    static func run(_ exe: String, _ args: [String], stdin: String? = nil, env: [String: String] = [:], mergeStderr: Bool = true) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [exe] + args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(); p.standardOutput = out
        if mergeStderr { p.standardError = out }
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("envault-\(UUID().uuidString).json")
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

// MARK: - Pre-commit scan

enum StagedScan {
    static func git(_ args: [String], in dir: String? = nil) throws -> (status: Int32, data: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + (dir.map { ["-C", $0] } ?? []) + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Staged (added, copied, modified, renamed) text files, as they will be committed.
    static func run(maxFileSize: Int = 512_000) throws -> [EnvHygiene.Finding] {
        let list = try git(["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"])
        guard list.status == 0 else { throw CLIError("not inside a git repository") }
        let paths = list.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [(path: String, text: String)] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard EnvHygiene.isScannable(path: path) || EnvDiscovery.isEnvFile(name) else { continue }
            let blob = try git(["show", ":" + path])
            guard blob.status == 0, blob.data.count <= maxFileSize, !blob.data.contains(0) else { continue }
            files.append((path, String(decoding: blob.data, as: UTF8.self)))
        }
        return EnvHygiene.scan(staged: files)
    }

    /// The repo's hooks folder, honouring core.hooksPath.
    static func hooksDir(repo: String) throws -> URL {
        let r = try git(["rev-parse", "--git-path", "hooks"], in: repo)
        guard r.status == 0 else { throw CLIError("\(repo) is not a git repository") }
        let path = String(decoding: r.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: repo).appendingPathComponent(path).standardizedFileURL
    }
}

/// Matches the app's MARKETING_VERSION; scripts/release.sh checks they agree.
let envaultVersion = "0.8.3"
