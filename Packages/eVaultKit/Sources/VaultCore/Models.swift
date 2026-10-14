import Foundation

/// What an item is. Unknown kinds round-trip so older clients never drop data.
public enum ItemKind: Hashable, Sendable, Codable, CustomStringConvertible {
    case envFile
    case secret
    case note
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .envFile: "envFile"
        case .secret: "secret"
        case .note: "note"
        case .unknown(let s): s
        }
    }
    public init(rawValue: String) {
        switch rawValue {
        case "envFile": self = .envFile
        case "secret": self = .secret
        case "note": self = .note
        default: self = .unknown(rawValue)
        }
    }
    public var description: String {
        switch self {
        case .envFile: "Env file"
        case .secret: "Secret"
        case .note: "Note"
        case .unknown(let s): s
        }
    }
    public static let known: [ItemKind] = [.envFile, .secret, .note]

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The secret content of an item. Encrypted as part of every revision.
public enum ItemPayload: Hashable, Sendable, Codable {
    /// Raw text of a dotenv file, preserved byte-for-byte.
    case envFile(text: String)
    /// A single value (API key, token) with free-form notes.
    case secret(value: String, notes: String)
    /// Markdown.
    case note(markdown: String)
    /// Payload written by a newer client; fields are kept verbatim.
    case unknown(kind: String, fields: [String: String])

    public var kind: ItemKind {
        switch self {
        case .envFile: .envFile
        case .secret: .secret
        case .note: .note
        case .unknown(let k, _): .unknown(k)
        }
    }

    /// The primary text of the payload (file text, secret value, markdown).
    public var primaryText: String {
        switch self {
        case .envFile(let t): t
        case .secret(let v, _): v
        case .note(let m): m
        case .unknown(_, let f): f["text"] ?? ""
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let f = try c.decode([String: String].self, forKey: .fields)
        switch ItemKind(rawValue: kind) {
        case .envFile: self = .envFile(text: f["text"] ?? "")
        case .secret: self = .secret(value: f["value"] ?? "", notes: f["notes"] ?? "")
        case .note: self = .note(markdown: f["markdown"] ?? "")
        case .unknown(let k): self = .unknown(kind: k, fields: f)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        let fields: [String: String]
        switch self {
        case .envFile(let t): fields = ["text": t]
        case .secret(let v, let n): fields = ["value": v, "notes": n]
        case .note(let m): fields = ["markdown": m]
        case .unknown(_, let f): fields = f
        }
        try c.encode(fields, forKey: .fields)
    }
}

/// Who wrote a revision. Cosmetic; helps "edited on MacBook Pro 2 hours ago".
public struct DeviceIdentity: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }

    private static let defaultsKey = "dk.dinhkhanh.evault.deviceIdentity"

    /// Stable per-user-per-Mac identity, created on first use.
    public static func current(defaults: UserDefaults = .standard) -> DeviceIdentity {
        if let data = defaults.data(forKey: defaultsKey), let d = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return d
        }
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let d = DeviceIdentity(id: UUID(), name: name)
        defaults.set(try? JSONEncoder().encode(d), forKey: defaultsKey)
        return d
    }
}

/// A full snapshot of a project's metadata at one point in time.
public struct ProjectRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: ULID
    public var projectId: UUID
    public var name: String
    public var tags: [String]
    public var deleted: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var device: DeviceIdentity

    public init(id: ULID = ULID(), projectId: UUID, name: String, tags: [String], deleted: Bool = false, createdAt: Date, modifiedAt: Date = Date(), device: DeviceIdentity) {
        self.id = id; self.projectId = projectId; self.name = name; self.tags = tags
        self.deleted = deleted; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.device = device
    }
}

/// A full snapshot of an item at one point in time. The item *is* its latest revision.
public struct ItemRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: ULID
    public var itemId: UUID
    public var projectId: UUID
    public var name: String
    public var tags: [String]
    public var payload: ItemPayload
    public var deleted: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var device: DeviceIdentity

    public init(id: ULID = ULID(), itemId: UUID, projectId: UUID, name: String, tags: [String], payload: ItemPayload, deleted: Bool = false, createdAt: Date, modifiedAt: Date = Date(), device: DeviceIdentity) {
        self.id = id; self.itemId = itemId; self.projectId = projectId; self.name = name; self.tags = tags
        self.payload = payload; self.deleted = deleted; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.device = device
    }
}

/// Read model for the UI: the current state of a project.
public struct Project: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var tags: [String]
    public var createdAt: Date
    public var modifiedAt: Date
    public var itemCount: Int

    public init(revision r: ProjectRevision, itemCount: Int) {
        id = r.projectId; name = r.name; tags = r.tags; createdAt = r.createdAt; modifiedAt = r.modifiedAt
        self.itemCount = itemCount
    }
}

/// Read model for the UI: the current state of an item.
public struct Item: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var tags: [String]
    public var payload: ItemPayload
    public var kind: ItemKind { payload.kind }
    public var createdAt: Date
    public var modifiedAt: Date
    public var modifiedBy: DeviceIdentity
    public var revisionId: ULID
    public var revisionCount: Int

    public init(revision r: ItemRevision, revisionCount: Int) {
        id = r.itemId; projectId = r.projectId; name = r.name; tags = r.tags; payload = r.payload
        createdAt = r.createdAt; modifiedAt = r.modifiedAt; modifiedBy = r.device; revisionId = r.id
        self.revisionCount = revisionCount
    }
}
