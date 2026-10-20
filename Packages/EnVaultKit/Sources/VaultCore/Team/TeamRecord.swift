import Foundation

/// A team vault this person belongs to, kept in their personal vault so every
/// one of their Macs opens it after unlock (FR-4). It pins the owner's signing
/// key as first seen, so a header someone swapped in later is refused.
public struct TeamRecord: Codable, Hashable, Sendable {
    public static let cloudKit = "cloudKit"

    public var vaultId: UUID
    /// The owner's Ed25519 public key, raw (`TeamHeader.owner.signingKey`).
    public var ownerKey: Data
    /// Where the files live: `cloudKit` for now; folder teams come later.
    /// A string, so records from a newer EnVault still decode.
    public var kind: String
    /// The CloudKit zone owner's record name for a vault shared with this
    /// person; nil for one they own (it is in their private database).
    public var zoneOwner: String?
    public var joinedAt: Date
    /// Left or removed: no longer opened.
    public var left: Bool

    public init(vaultId: UUID, ownerKey: Data, kind: String = TeamRecord.cloudKit, zoneOwner: String? = nil, joinedAt: Date = Date(), left: Bool = false) {
        self.vaultId = vaultId; self.ownerKey = ownerKey; self.kind = kind
        self.zoneOwner = zoneOwner; self.joinedAt = joinedAt; self.left = left
    }
}

struct TeamRecordRevision: Codable, Sendable, Identifiable {
    var id: ULID
    var record: TeamRecord
}
