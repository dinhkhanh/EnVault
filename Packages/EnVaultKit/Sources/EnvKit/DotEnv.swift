import Foundation

/// How a value was quoted in the source file. Preserved so edits don't churn the file.
public enum EnvQuote: Hashable, Sendable { case none, single, double }

public struct EnvEntry: Hashable, Sendable {
    public var key: String
    public var value: String
    public var quote: EnvQuote
    public var exported: Bool
    public var inlineComment: String?

    public init(key: String, value: String, quote: EnvQuote = .none, exported: Bool = false, inlineComment: String? = nil) {
        self.key = key; self.value = value; self.quote = quote; self.exported = exported; self.inlineComment = inlineComment
    }
}

public struct EnvLine: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case blank
        case comment(String)
        case entry(EnvEntry)
        case invalid(reason: String)
    }
    /// Zero-based line number.
    public let id: Int
    public var raw: String
    public var kind: Kind

    public var entry: EnvEntry? {
        if case .entry(let e) = kind { return e }
        return nil
    }
}

/// A parsed dotenv file. Keeps raw lines so that `text` round-trips unchanged
/// unless an entry was modified.
public struct EnvDocument: Hashable, Sendable {
    public var lines: [EnvLine]
    public var trailingNewline: Bool

    public init(lines: [EnvLine], trailingNewline: Bool) {
        self.lines = lines
        self.trailingNewline = trailingNewline
    }

    public var entries: [EnvEntry] { lines.compactMap(\.entry) }

    /// Last definition wins, like every dotenv loader.
    public var values: [String: String] {
        var out: [String: String] = [:]
        for e in entries { out[e.key] = e.value }
        return out
    }

    public subscript(key: String) -> String? { values[key] }

    public var text: String {
        let body = lines.map(\.raw).joined(separator: "\n")
        return trailingNewline && !lines.isEmpty ? body + "\n" : body
    }

    /// Returns a copy with `key` set to `value`, editing the last existing
    /// definition in place or appending a new line.
    public func setting(_ key: String, to value: String) -> EnvDocument {
        var doc = self
        if let idx = doc.lines.lastIndex(where: { $0.entry?.key == key }), var e = doc.lines[idx].entry {
            e.value = value
            doc.lines[idx].kind = .entry(e)
            doc.lines[idx].raw = DotEnv.serialize(e)
        } else {
            let e = EnvEntry(key: key, value: value, quote: DotEnv.needsQuoting(value) ? .double : .none)
            doc.lines.append(EnvLine(id: doc.lines.count, raw: DotEnv.serialize(e), kind: .entry(e)))
            doc.trailingNewline = true
        }
        return doc
    }

    public func removing(_ key: String) -> EnvDocument {
        var doc = self
        doc.lines.removeAll { $0.entry?.key == key }
        doc.lines = doc.lines.enumerated().map { EnvLine(id: $0.offset, raw: $0.element.raw, kind: $0.element.kind) }
        return doc
    }
}

public enum DotEnv {
    public static func parse(_ text: String) -> EnvDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var rawLines = normalized.components(separatedBy: "\n")
        let trailing = normalized.hasSuffix("\n")
        if trailing { rawLines.removeLast() }
        let lines = rawLines.enumerated().map { i, raw in EnvLine(id: i, raw: raw, kind: parseLine(raw)) }
        return EnvDocument(lines: lines, trailingNewline: trailing || rawLines.isEmpty)
    }

    static func parseLine(_ raw: String) -> EnvLine.Kind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("#") { return .comment(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)) }

        var rest = Substring(trimmed)
        var exported = false
        if rest.hasPrefix("export "), rest.dropFirst(7).contains("=") {
            exported = true
            rest = rest.dropFirst(7).drop(while: { $0 == " " || $0 == "\t" })
        }
        guard let eq = rest.firstIndex(of: "=") else { return .invalid(reason: "missing '='") }
        let key = rest[..<eq].trimmingCharacters(in: .whitespaces)
        guard isValidKey(key) else { return .invalid(reason: "invalid key '\(key)'") }
        var valuePart = rest[rest.index(after: eq)...].drop(while: { $0 == " " || $0 == "\t" })

        var quote = EnvQuote.none
        var value = ""
        var inlineComment: String?

        if let first = valuePart.first, first == "\"" || first == "'" {
            quote = first == "\"" ? .double : .single
            valuePart = valuePart.dropFirst()
            var closed = false
            var i = valuePart.startIndex
            while i < valuePart.endIndex {
                let c = valuePart[i]
                if quote == .double, c == "\\", valuePart.index(after: i) < valuePart.endIndex {
                    let n = valuePart[valuePart.index(after: i)]
                    switch n {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": value.append("\r")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    case "$": value.append("$")
                    default: value.append("\\"); value.append(n)
                    }
                    i = valuePart.index(i, offsetBy: 2)
                    continue
                }
                if c == first { closed = true; i = valuePart.index(after: i); break }
                value.append(c)
                i = valuePart.index(after: i)
            }
            if !closed {
                // Unterminated quote: keep the literal text, flag nothing; loaders differ here.
                return .entry(EnvEntry(key: key, value: String(valuePart), quote: .none, exported: exported))
            }
            let tail = valuePart[i...].trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("#") { inlineComment = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces) }
        } else {
            // Unquoted: value runs until " #" (inline comment); trailing whitespace trimmed.
            let s = String(valuePart)
            if let r = s.range(of: " #") {
                value = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                inlineComment = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("#") {
                value = ""
                inlineComment = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                value = s.trimmingCharacters(in: .whitespaces)
            }
        }
        return .entry(EnvEntry(key: key, value: value, quote: quote, exported: exported, inlineComment: inlineComment))
    }

    public static func isValidKey(_ key: String) -> Bool {
        guard let f = key.unicodeScalars.first, f == "_" || CharacterSet.letters.contains(f) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || $0 == "." || $0 == "-" || CharacterSet.alphanumerics.contains($0) }
    }

    public static func needsQuoting(_ value: String) -> Bool {
        value.isEmpty == false && (value.contains(" ") || value.contains("#") || value.contains("\n") || value.contains("\"") || value.contains("'") || value != value.trimmingCharacters(in: .whitespaces))
    }

    public static func serialize(_ e: EnvEntry) -> String {
        var quote = e.quote
        if quote == .none, needsQuoting(e.value) { quote = .double }
        if quote == .single, e.value.contains("'") { quote = .double }
        let v: String
        switch quote {
        case .none: v = e.value
        case .single: v = "'" + e.value + "'"
        case .double:
            v = "\"" + e.value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        var s = (e.exported ? "export " : "") + e.key + "=" + v
        if let c = e.inlineComment { s += " # " + c }
        return s
    }

    public static func serialize(_ doc: EnvDocument) -> String { doc.text }
}
