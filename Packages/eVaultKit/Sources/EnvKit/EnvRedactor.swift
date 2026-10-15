import Foundation

/// Replaces an env file's secret values with `[redacted:KEY]` in a byte
/// stream, so a command run with secrets (`evault run`) can't echo them into
/// an AI agent's context or a CI log. Values may arrive split across chunks:
/// the redactor holds back just enough bytes to see every match whole.
///
/// It catches values printed verbatim, not encoded or transformed ones.
public struct EnvRedactor {
    private let patterns: [(bytes: [UInt8], token: [UInt8])]
    private let hold: Int
    /// No value spans lines, so whole lines can go out at once.
    private let lineSafe: Bool
    private var buffer: [UInt8] = []

    /// Values shorter than `minLength`, and values that look non-secret
    /// (ports, booleans, localhost URLs), are left alone.
    public init(_ doc: EnvDocument, minLength: Int = 4) {
        var seen = Set<String>()
        var list: [(bytes: [UInt8], token: [UInt8])] = []
        for e in doc.entries where Self.redacts(e, minLength: minLength) {
            guard seen.insert(e.value).inserted else { continue }
            list.append((Array(e.value.utf8), Array("[redacted:\(e.key)]".utf8)))
        }
        // Longest first, so a value that contains another is replaced whole.
        patterns = list.sorted { $0.bytes.count > $1.bytes.count }
        hold = max((patterns.first?.bytes.count ?? 1) - 1, 0)
        lineSafe = !patterns.contains { $0.bytes.contains(10) }
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// Whether this entry's value gets redacted.
    public static func redacts(_ e: EnvEntry, minLength: Int = 4) -> Bool {
        e.value.count >= minLength && EnvHygiene.isLikelySecret(key: e.key, value: e.value)
    }

    /// Redacts what can be decided now and keeps the rest for the next chunk.
    public mutating func feed(_ chunk: some Sequence<UInt8>) -> [UInt8] {
        buffer.append(contentsOf: chunk)
        var end = buffer.count - hold
        if lineSafe, let nl = buffer.lastIndex(of: 10) { end = max(end, nl + 1) }
        return drain(upTo: end)
    }

    /// Flushes everything held back (end of stream).
    public mutating func finish() -> [UInt8] { drain(upTo: buffer.count) }

    public static func redact(_ text: String, using doc: EnvDocument) -> String {
        var r = EnvRedactor(doc)
        let out = r.feed(Array(text.utf8)) + r.finish()
        return String(decoding: out, as: UTF8.self)
    }

    /// Positions before `end` are decided: any match starting there fits in the buffer.
    private mutating func drain(upTo end: Int) -> [UInt8] {
        guard end > 0 else { return [] }
        if patterns.isEmpty {
            defer { buffer.removeFirst(end) }
            return Array(buffer[..<end])
        }
        var out: [UInt8] = []
        out.reserveCapacity(end)
        var i = 0
        while i < end {
            if let p = match(at: i) {
                out.append(contentsOf: p.token)
                i += p.bytes.count
            } else {
                out.append(buffer[i])
                i += 1
            }
        }
        buffer.removeFirst(min(i, buffer.count))
        return out
    }

    private func match(at i: Int) -> (bytes: [UInt8], token: [UInt8])? {
        let first = buffer[i]
        for p in patterns where p.bytes[0] == first && i + p.bytes.count <= buffer.count {
            var j = 1
            while j < p.bytes.count, buffer[i + j] == p.bytes[j] { j += 1 }
            if j == p.bytes.count { return p }
        }
        return nil
    }
}
