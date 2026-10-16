import Foundation

/// The pre-commit hook that runs `envault scan --staged`. Lives between
/// markers so it can be added to, and removed from, an existing hook.
public enum GitHook {
    public static let begin = "# >>> EnVault secret scan >>>"
    public static let end = "# <<< EnVault secret scan <<<"

    /// Falls back to the CLI bundled in the app, since GUI git clients run
    /// hooks with a minimal PATH.
    public static let block = """
    \(begin)
    ENVAULT_BIN="$(command -v envault 2>/dev/null || echo /Applications/EnVault.app/Contents/Helpers/envault)"
    if [ -x "$ENVAULT_BIN" ]; then
      "$ENVAULT_BIN" scan --staged || exit $?
    fi
    \(end)
    """

    public static func isInstalled(in hook: String) -> Bool { hook.contains(begin) }

    /// The hook with the EnVault block added right after the shebang (so an
    /// early `exit 0` further down can't skip it). Unchanged if already present.
    public static func installing(into existing: String?) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "#!/bin/sh\n" + block + "\n"
        }
        if isInstalled(in: existing) { return existing }
        var lines = existing.components(separatedBy: "\n")
        if lines.first?.hasPrefix("#!") == true {
            lines.insert(block, at: 1)
        } else {
            lines.insert(contentsOf: ["#!/bin/sh", block], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// The hook without the EnVault block; nil when nothing else is left in it.
    public static func removing(from existing: String) -> String? {
        var out: [String] = []
        var inside = false
        for line in existing.components(separatedBy: "\n") {
            if line == begin { inside = true; continue }
            if line == end { inside = false; continue }
            if !inside { out.append(line) }
        }
        let rest = out.joined(separator: "\n")
        let meaningful = out.filter { !$0.hasPrefix("#!") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return meaningful.isEmpty ? nil : rest
    }

    /// Installs into `<hooksDir>/pre-commit`, making it executable.
    public static func install(hooksDir: URL) throws -> URL {
        let url = hooksDir.appendingPathComponent("pre-commit")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        try installing(into: existing).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    public static func uninstall(hooksDir: URL) throws {
        let url = hooksDir.appendingPathComponent("pre-commit")
        guard let existing = try? String(contentsOf: url, encoding: .utf8), isInstalled(in: existing) else { return }
        if let rest = removing(from: existing) {
            try rest.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }
}
