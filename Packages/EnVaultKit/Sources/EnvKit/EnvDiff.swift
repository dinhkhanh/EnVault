import Foundation

public enum EnvChange: Hashable, Sendable, Identifiable {
    case added(key: String, value: String)
    case removed(key: String, value: String)
    case changed(key: String, old: String, new: String)

    public var key: String {
        switch self {
        case .added(let k, _), .removed(let k, _), .changed(let k, _, _): k
        }
    }
    public var id: String { key }
}

public enum EnvDiff {
    /// Key-level diff from `a` to `b`, sorted by key. Order and comments are ignored.
    public static func diff(_ a: EnvDocument, _ b: EnvDocument) -> [EnvChange] {
        let va = a.values, vb = b.values
        var out: [EnvChange] = []
        for (k, v) in va {
            if let nv = vb[k] {
                if nv != v { out.append(.changed(key: k, old: v, new: nv)) }
            } else {
                out.append(.removed(key: k, value: v))
            }
        }
        for (k, v) in vb where va[k] == nil { out.append(.added(key: k, value: v)) }
        return out.sorted { $0.key < $1.key }
    }

    /// Keys present in `template` (e.g. `.env.example`) but missing in `doc`.
    public static func missingKeys(in doc: EnvDocument, comparedTo template: EnvDocument) -> [String] {
        let have = Set(doc.values.keys)
        return template.entries.map(\.key).filter { !have.contains($0) }
    }
}
