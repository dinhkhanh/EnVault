import Foundation
import CryptoKit

/// `.evr` file: `"EVR1"` magic + AES-256-GCM sealed box (nonce ‖ ciphertext ‖ tag)
/// of a JSON-encoded revision. The AAD binds the blob to its vault, owner and
/// revision id, so a file cannot be copied to another item/revision path.
public enum RevisionFile {
    public static let fileExtension = "evr"
    static let magic = Data("EVR1".utf8)

    public enum Scope: String, Sendable { case project, item, identity, team }

    // "evault-rev" is the format label from before the rename; changing it breaks every vault.
    static func aad(vaultId: UUID, scope: Scope, ownerId: UUID, revisionId: ULID) -> Data {
        Data("evault-rev:1:\(vaultId.uuidString):\(scope.rawValue):\(ownerId.uuidString):\(revisionId.string)".utf8)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T, vaultId: UUID, scope: Scope, ownerId: UUID, revisionId: ULID, key: VaultKey) throws -> Data {
        let plain = try encoder.encode(value)
        let box = try AES.GCM.seal(plain, using: key.key, authenticating: aad(vaultId: vaultId, scope: scope, ownerId: ownerId, revisionId: revisionId))
        return magic + box.combined!
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, vaultId: UUID, scope: Scope, ownerId: UUID, revisionId: ULID, key: VaultKey) throws -> T {
        guard data.count > magic.count, data.prefix(magic.count) == magic else {
            throw VaultError.corruptRevision("bad magic")
        }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            plain = try AES.GCM.open(box, using: key.key, authenticating: aad(vaultId: vaultId, scope: scope, ownerId: ownerId, revisionId: revisionId))
        } catch {
            throw VaultError.corruptRevision("authentication failed for \(revisionId)")
        }
        do {
            return try decoder.decode(type, from: plain)
        } catch {
            throw VaultError.corruptRevision("json: \(error)")
        }
    }
}
