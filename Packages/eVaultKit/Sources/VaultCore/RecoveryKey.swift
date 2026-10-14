import Foundation
import CryptoKit

/// A second way to unwrap the vault key: a random 160-bit key shown once to
/// the user as `EVLT-XXXX-XXXX-…`. Losing the passphrase no longer loses the
/// vault. Stored in `vault.json` as another AES-GCM wrap of the vault key.
public struct RecoveryWrap: Codable, Equatable, Sendable {
    public var kdf: KDFParams
    public var wrappedVaultKey: Data
    public var createdAt: Date
}

public enum RecoveryKey {
    static let prefix = "EVLT"
    static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789") // no 0/O/1/I/L/U

    /// 32 characters from a 30-symbol alphabet ≈ 157 bits of entropy.
    public static func generate() -> String {
        let bytes = SecureRandom.bytes(32)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        return ([prefix] + groups).joined(separator: "-")
    }

    /// Accepts any spacing/dashes/case; returns the 32 canonical symbols or nil.
    public static func normalize(_ input: String) -> String? {
        var s = input.uppercased().filter { $0.isLetter || $0.isNumber }
        if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        s = String(s.map { c -> Character in
            switch c { case "0": "O"; case "1", "I": "L"; default: c }
        })
        guard s.count == 32, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return s
    }

    public static func display(_ canonical: String) -> String {
        let chars = Array(canonical)
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        return ([prefix] + groups).joined(separator: "-")
    }
}

extension KeyHierarchy {
    static func recoveryAAD(for vaultId: UUID) -> Data { Data("evault-recovery-key:\(vaultId.uuidString)".utf8) }

    /// Adds (or replaces) the recovery wrap. Returns the key to show the user.
    public static func addRecovery(header: VaultHeader, vaultKey: VaultKey, kdf: KDFParams = .random()) throws -> (header: VaultHeader, recoveryKey: String) {
        let key = RecoveryKey.generate()
        let canonical = RecoveryKey.normalize(key)!
        let kek = try KDF.deriveKEK(passphrase: canonical, params: kdf)
        let box = try AES.GCM.seal(vaultKey.data, using: kek, authenticating: recoveryAAD(for: header.vaultId))
        var h = header
        h.recovery = RecoveryWrap(kdf: kdf, wrappedVaultKey: box.combined!, createdAt: Date())
        return (h, key)
    }

    public static func unlock(header: VaultHeader, recoveryKey: String) throws -> VaultKey {
        guard let r = header.recovery else { throw VaultError.noRecoveryKey }
        guard let canonical = RecoveryKey.normalize(recoveryKey) else { throw VaultError.wrongRecoveryKey }
        let kek = try KDF.deriveKEK(passphrase: canonical, params: r.kdf)
        do {
            let box = try AES.GCM.SealedBox(combined: r.wrappedVaultKey)
            let raw = try AES.GCM.open(box, using: kek, authenticating: recoveryAAD(for: header.vaultId))
            guard raw.count == 32 else { throw VaultError.corruptHeader("vault key has wrong length") }
            return VaultKey(data: raw)
        } catch is CryptoKitError {
            throw VaultError.wrongRecoveryKey
        }
    }
}
