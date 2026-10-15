import Foundation

/// Problems in a dotenv file that loaders silently tolerate but that usually
/// mean a mistake: a key defined twice, a value left empty or as a placeholder,
/// a line no loader understands.
public enum EnvLint {
    public struct Issue: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable {
            case duplicateKey, emptyValue, placeholderValue, invalidLine, unterminatedQuote
        }
        public var id: String { "\(line):\(kind.rawValue)" }
        /// Zero-based line number.
        public var line: Int
        public var key: String?
        public var kind: Kind
        public var message: String
    }

    public static func check(_ doc: EnvDocument) -> [Issue] {
        var out: [Issue] = []
        var lastLine: [String: Int] = [:]
        for line in doc.lines {
            if case .entry(let e) = line.kind { lastLine[e.key] = line.id }
        }
        for line in doc.lines {
            switch line.kind {
            case .invalid(let reason):
                out.append(Issue(line: line.id, key: nil, kind: .invalidLine, message: "Line \(line.id + 1) is not KEY=value (\(reason)); loaders skip it."))
            case .entry(let e):
                if let last = lastLine[e.key], last != line.id {
                    out.append(Issue(line: line.id, key: e.key, kind: .duplicateKey, message: "\(e.key) is defined again on line \(last + 1), which wins."))
                }
                if e.quote == .none, let f = rawValue(line.raw).first, f == "\"" || f == "'" {
                    out.append(Issue(line: line.id, key: e.key, kind: .unterminatedQuote, message: "\(e.key) opens a quote that is never closed."))
                } else if e.value.isEmpty {
                    out.append(Issue(line: line.id, key: e.key, kind: .emptyValue, message: "\(e.key) is empty."))
                } else if isPlaceholder(e.value) {
                    out.append(Issue(line: line.id, key: e.key, kind: .placeholderValue, message: "\(e.key) looks like a placeholder (“\(e.value)”)."))
                }
            default:
                break
            }
        }
        return out
    }

    private static func rawValue(_ raw: String) -> Substring {
        guard let eq = raw.firstIndex(of: "=") else { return "" }
        return raw[raw.index(after: eq)...].drop(while: { $0 == " " || $0 == "\t" })
    }

    static func isPlaceholder(_ v: String) -> Bool {
        let s = v.lowercased()
        if ["changeme", "change_me", "change-me", "todo", "tbd", "fixme", "replace_me", "replaceme", "secret", "password", "xxx"].contains(s) { return true }
        if s.count >= 3, Set(s).count == 1, s.first == "x" || s.first == "*" { return true }
        if s.hasPrefix("<"), s.hasSuffix(">") { return true }
        if s.hasPrefix("your_") || s.hasPrefix("your-") || s.hasSuffix("_here") || s.hasSuffix("-here") { return true }
        return false
    }
}
