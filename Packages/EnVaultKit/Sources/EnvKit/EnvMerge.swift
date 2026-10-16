import Foundation

/// Three-way merge of two edits of the same dotenv file, key by key.
///
/// The result is `edited` (its lines, comments and order are kept) with the
/// key changes made in `other` applied on top: values set, keys added (the
/// whole line, as `other` wrote it), keys removed. A key changed on both sides
/// to different values, or changed on one side and removed on the other, is a
/// conflict and nothing is merged. Comment and blank-line edits in `other`
/// are not carried over.
public enum EnvMerge {
    public struct Result: Equatable, Sendable {
        /// The merged text; nil when there are conflicts.
        public var text: String?
        /// Keys changed differently on both sides, sorted.
        public var conflicts: [String]
    }

    public static func merge(base: String, edited: String, other: String) -> Result {
        let b = DotEnv.parse(base).values
        let e = DotEnv.parse(edited)
        let o = DotEnv.parse(other)
        let ev = e.values, ov = o.values

        let otherChanges = Set(b.keys).union(ov.keys).filter { b[$0] != ov[$0] }
        let conflicts = otherChanges.filter { key in
            let editedChanged = b[key] != ev[key]
            return editedChanged && ev[key] != ov[key]
        }.sorted()
        guard conflicts.isEmpty else { return Result(text: nil, conflicts: conflicts) }

        var doc = e
        // Apply in the order `other` lists its keys, so added keys keep that order.
        let otherOrder = o.entries.map(\.key)
        let ordered = otherChanges.sorted { (otherOrder.lastIndex(of: $0) ?? .max, $0) < (otherOrder.lastIndex(of: $1) ?? .max, $1) }
        for key in ordered where ev[key] != ov[key] {
            if ov[key] == nil {
                doc = doc.removing(key)
            } else if let line = o.lines.last(where: { $0.entry?.key == key }) {
                if let i = doc.lines.lastIndex(where: { $0.entry?.key == key }) {
                    doc.lines[i].raw = line.raw
                    doc.lines[i].kind = line.kind
                } else {
                    doc.lines.append(EnvLine(id: doc.lines.count, raw: line.raw, kind: line.kind))
                    doc.trailingNewline = true
                }
            }
        }
        return Result(text: doc.text, conflicts: [])
    }
}
