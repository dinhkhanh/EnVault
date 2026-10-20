import Foundation
import CryptoKit

/// Length-prefixed fields under a versioned label: what every Team signature
/// covers, so no two different values serialise to the same bytes.
struct CanonicalBytes {
    private(set) var data: Data

    init(_ label: String) { data = Data(label.utf8) }

    mutating func add(_ field: Data) {
        var n = UInt32(field.count).bigEndian
        data.append(Data(bytes: &n, count: 4))
        data.append(field)
    }
    mutating func add(_ s: String) { add(Data(s.utf8)) }
    mutating func add(_ id: UUID) { add(id.uuidString) }
    mutating func add(_ id: ULID) { add(id.string) }
}

/// `vault.json` of a team vault (format 2). Written once by the owner and
/// never replaced: the owner's public identity, signed by the owner. Every
/// membership change traces back to this key (FR-31).
///
/// Format 1 readers refuse it (`VaultHeader.decode` checks the version first).
public struct TeamHeader: Codable, Equatable, Sendable {
    public static let formatVersion = 2
    public static let kind = "team"

    public var formatVersion: Int
    public var kind: String
    public var vaultId: UUID
    public var createdAt: Date
    public var owner: PublicIdentity
    /// Ed25519 by the owner's signing key over `signedBytes`.
    public var signature: Data

    public static func create(owner: UserIdentity, vaultId: UUID = UUID(), createdAt: Date = Date()) throws -> TeamHeader {
        var h = TeamHeader(formatVersion: formatVersion, kind: kind, vaultId: vaultId,
                           createdAt: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down)),
                           owner: try owner.publicIdentity(), signature: Data())
        h.signature = try owner.signingKey.signature(for: h.signedBytes)
        return h
    }

    var signedBytes: Data {
        var c = CanonicalBytes("envault-team-header:1")
        c.add(String(formatVersion))
        c.add(kind)
        c.add(vaultId)
        c.add(String(Int64(createdAt.timeIntervalSince1970)))
        c.add(owner.signedBytes)
        return c.data
    }

    /// The owner's identity is self-signed and signed this header.
    public var isValid: Bool {
        guard formatVersion == Self.formatVersion, kind == Self.kind, owner.isValid,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: owner.signingKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> TeamHeader {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let h: TeamHeader
        do { h = try dec.decode(TeamHeader.self, from: data) } catch { throw VaultError.corruptHeader(String(describing: error)) }
        guard h.isValid else { throw VaultError.corruptHeader("team header signature does not verify") }
        return h
    }
}
