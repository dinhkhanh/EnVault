import Foundation
import CryptoKit

/// `vault.json` — the only file in a vault that is not a revision.
/// Contains nothing secret: ciphertext of the vault key, KDF params, ids.
public struct VaultHeader: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileName = "vault.json"

    public var formatVersion: Int
    public var vaultId: UUID
    public var createdAt: Date
    public var kdf: KDFParams
    /// AES-GCM sealed box (nonce ‖ ciphertext ‖ tag) of the 32-byte vault key, keyed by the KEK.
    public var wrappedVaultKey: Data

    public init(formatVersion: Int = VaultHeader.currentFormatVersion, vaultId: UUID, createdAt: Date, kdf: KDFParams, wrappedVaultKey: Data) {
        self.formatVersion = formatVersion
        self.vaultId = vaultId
        self.createdAt = createdAt
        self.kdf = kdf
        self.wrappedVaultKey = wrappedVaultKey
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> VaultHeader {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let h = try dec.decode(VaultHeader.self, from: data)
            guard h.formatVersion <= currentFormatVersion else { throw VaultError.unsupportedFormatVersion(h.formatVersion) }
            return h
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.corruptHeader(String(describing: error))
        }
    }
}

/// The random 256-bit key that encrypts every revision.
public struct VaultKey: Sendable, Equatable {
    public let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }
    public init(data: Data) { self.key = SymmetricKey(data: data) }
    public static func random() -> VaultKey { VaultKey(key: SymmetricKey(size: .bits256)) }
    public var data: Data { key.withUnsafeBytes { Data($0) } }
}

public enum KeyHierarchy {
    static func aad(for vaultId: UUID) -> Data { Data("evault-vault-key:\(vaultId.uuidString)".utf8) }

    /// Creates a brand-new header + vault key for a passphrase.
    public static func createVault(passphrase: String, kdf: KDFParams = .random()) throws -> (header: VaultHeader, vaultKey: VaultKey) {
        let vaultId = UUID()
        let vk = VaultKey.random()
        let kek = try KDF.deriveKEK(passphrase: passphrase, params: kdf)
        let box = try AES.GCM.seal(vk.data, using: kek, authenticating: aad(for: vaultId))
        let header = VaultHeader(vaultId: vaultId, createdAt: Date(), kdf: kdf, wrappedVaultKey: box.combined!)
        return (header, vk)
    }

    /// Unwraps the vault key. A GCM tag failure means a wrong passphrase.
    public static func unlock(header: VaultHeader, passphrase: String) throws -> VaultKey {
        let kek = try KDF.deriveKEK(passphrase: passphrase, params: header.kdf)
        do {
            let box = try AES.GCM.SealedBox(combined: header.wrappedVaultKey)
            let raw = try AES.GCM.open(box, using: kek, authenticating: aad(for: header.vaultId))
            guard raw.count == 32 else { throw VaultError.corruptHeader("vault key has wrong length") }
            return VaultKey(data: raw)
        } catch is CryptoKitError {
            throw VaultError.wrongPassphrase
        }
    }

    /// Re-wraps the existing vault key under a new passphrase. No data is re-encrypted.
    public static func rewrap(header: VaultHeader, vaultKey: VaultKey, newPassphrase: String, kdf: KDFParams = .random()) throws -> VaultHeader {
        let kek = try KDF.deriveKEK(passphrase: newPassphrase, params: kdf)
        let box = try AES.GCM.seal(vaultKey.data, using: kek, authenticating: aad(for: header.vaultId))
        var h = header
        h.kdf = kdf
        h.wrappedVaultKey = box.combined!
        return h
    }
}
