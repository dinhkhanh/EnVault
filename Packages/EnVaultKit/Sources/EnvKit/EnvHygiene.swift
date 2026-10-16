import Foundation

public enum EnvHygiene {
    /// `.env.example`: same keys, comments and layout, values blanked (or a
    /// placeholder derived from the key when the value looks non-secret).
    public static func example(from doc: EnvDocument, placeholders: Bool = true) -> String {
        var out: [String] = []
        for line in doc.lines {
            switch line.kind {
            case .entry(var e):
                e.value = placeholders ? placeholder(for: e.key, value: e.value) : ""
                e.quote = .none
                out.append(DotEnv.serialize(e))
            default:
                out.append(line.raw)
            }
        }
        return out.joined(separator: "\n") + (doc.trailingNewline && !out.isEmpty ? "\n" : "")
    }

    /// False for values that are obviously not secret (ports, booleans, localhost URLs).
    public static func isLikelySecret(key: String, value: String) -> Bool {
        !value.isEmpty && placeholder(for: key, value: value).isEmpty
    }

    /// Keep obviously non-secret values (ports, booleans, localhost URLs), blank the rest.
    static func placeholder(for key: String, value: String) -> String {
        let k = key.uppercased()
        if value.isEmpty { return "" }
        if ["true", "false", "0", "1"].contains(value.lowercased()) { return value }
        if Int(value) != nil { return value }
        if value.hasPrefix("http://localhost") || value.hasPrefix("http://127.0.0.1") { return value }
        if k.hasSuffix("_PORT") || k.hasSuffix("_HOST") || k == "NODE_ENV" || k == "ENV" || k == "LOG_LEVEL" { return value }
        return ""
    }

    /// Per-key last-changed timestamps, given revisions newest-first with
    /// their env text. A key's age is the time since its value last changed.
    public static func keyAges(revisions: [(date: Date, text: String)], now: Date = Date()) -> [String: Date] {
        guard let newest = revisions.first else { return [:] }
        let current = DotEnv.parse(newest.text).values
        var lastChanged: [String: Date] = [:]
        for key in current.keys { lastChanged[key] = newest.date }
        // Walk back while the value is unchanged; the first revision that differs stops the walk.
        for (key, value) in current {
            for r in revisions.dropFirst() {
                let v = DotEnv.parse(r.text).values[key]
                if v == value { lastChanged[key] = r.date } else { break }
            }
        }
        return lastChanged
    }

    public struct Finding: Hashable, Sendable, Identifiable {
        public var id: String { "\(file):\(line):\(kind)" }
        public var file: String
        public var line: Int
        public var kind: String
        public var excerpt: String
    }

    /// Lightweight secret scanner for source trees: well-known token shapes
    /// plus high-entropy assignments. Not a replacement for gitleaks, but
    /// catches the common "pasted a key into a config" mistake.
    public static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("AWS access key", try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#)),
        ("GitHub token", try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#)),
        ("Stripe key", try! NSRegularExpression(pattern: #"\b[sr]k_(live|test)_[0-9a-zA-Z]{20,}\b"#)),
        ("Slack token", try! NSRegularExpression(pattern: #"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#)),
        ("OpenAI key", try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{20,}\b"#)),
        ("Google API key", try! NSRegularExpression(pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#)),
        ("Private key block", try! NSRegularExpression(pattern: #"-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#)),
        ("JWT", try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#)),
        ("Secret assignment", try! NSRegularExpression(pattern: #"(?i)\b(secret|password|passwd|api[_-]?key|token|private[_-]?key)\b\s*[:=]\s*['"][^'"\s]{12,}['"]"#)),
    ]

    public static func scan(text: String, file: String) -> [Finding] {
        var out: [Finding] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let l = String(line)
            if l.contains("example") || l.contains("placeholder") || l.contains("xxxx") || l.contains(allowMarker) { continue }
            let range = NSRange(l.startIndex..., in: l)
            for (kind, re) in patterns where re.firstMatch(in: l, range: range) != nil {
                out.append(Finding(file: file, line: i + 1, kind: kind, excerpt: redact(l)))
                break
            }
        }
        return out
    }

    /// A line containing this is never reported (for test fixtures and the like).
    public static let allowMarker = "envault:allow"

    static let textExt: Set<String> = ["", "env", "txt", "md", "json", "yml", "yaml", "toml", "ini", "cfg", "conf", "js", "ts", "tsx", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "swift", "java", "kt", "php", "sh", "zsh", "bash", "fish", "xml", "plist", "tf", "hcl", "tfvars", "sql", "cs", "c", "h", "cpp", "m", "mm", "properties", "gradle", "example", "local", "development", "production", "staging", "test", "vue", "svelte", "astro", "dart", "ex", "exs", "pem", "key", "npmrc", "pypirc", "netrc"]

    /// Whether a file of this name is text worth scanning.
    public static func isScannable(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return textExt.contains((name as NSString).pathExtension.lowercased()) || name.hasPrefix(".")
    }

    /// Scans files about to be committed: their content, plus a finding for any
    /// real env file (not a template) being added at all.
    public static func scan(staged files: [(path: String, text: String)]) -> [Finding] {
        var out: [Finding] = []
        for f in files {
            let name = (f.path as NSString).lastPathComponent
            if EnvDiscovery.isEnvFile(name), !DotEnv.parse(f.text).entries.filter({ !$0.value.isEmpty }).isEmpty {
                out.append(Finding(file: f.path, line: 1, kind: "Env file committed", excerpt: "\(name) with values; add it to .gitignore and keep it in EnVault"))
                continue
            }
            out += scan(text: f.text, file: f.path)
        }
        return out
    }

    /// Scans a folder tree (skipping dependencies, binaries and the vault's own files).
    public static func scan(folder: URL, maxFileSize: Int = 512_000) -> [Finding] {
        let skipDirs: Set<String> = ["node_modules", ".git", "vendor", "Pods", "build", "dist", ".next", "target", "DerivedData", ".build", ".venv", "venv"]
        var out: [Finding] = []
        let base = folder.resolvingSymlinksInPath().path + "/"
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey], options: []) else { return [] }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { if skipDirs.contains(u.lastPathComponent) { e.skipDescendants() }; continue }
            guard v?.isRegularFile == true, (v?.fileSize ?? 0) <= maxFileSize, textExt.contains(u.pathExtension.lowercased()) else { continue }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let full = u.resolvingSymlinksInPath().path
            let rel = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : u.lastPathComponent
            out += scan(text: text, file: rel)
        }
        return out
    }

    /// Keeps the start of a line and hides the secret-looking tail.
    static func redact(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count > 24 else { return String(repeating: "•", count: t.count) }
        return String(t.prefix(16)) + "…" + String(repeating: "•", count: 8)
    }
}
