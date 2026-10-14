import Foundation

public enum EnvExport {
    /// `export KEY='value'` lines, safe to `eval` or `source` in a POSIX shell.
    public static func shell(_ doc: EnvDocument) -> String {
        doc.entries.map { "export \($0.key)=\(shellQuote($0.value))" }.joined(separator: "\n") + (doc.entries.isEmpty ? "" : "\n")
    }

    /// `KEY=value` lines on one line, for prefixing a command.
    public static func inlineCommand(_ doc: EnvDocument) -> String {
        doc.entries.map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
    }

    public static func json(_ doc: EnvDocument) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(doc.values), encoding: .utf8)) ?? "{}"
    }

    public static func yaml(_ doc: EnvDocument) -> String {
        doc.values.keys.sorted().map { k in "\(k): \(yamlQuote(doc.values[k]!))" }.joined(separator: "\n") + "\n"
    }

    /// GitHub Actions / docker `--env-file` style: plain `KEY=value`, no quotes, no comments.
    public static func plain(_ doc: EnvDocument) -> String {
        doc.entries.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
