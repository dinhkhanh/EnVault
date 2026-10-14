import Foundation
import CommonCrypto
import CryptoKit

/// Key derivation parameters, stored in the vault header so they can be
/// upgraded later (e.g. to Argon2id) without changing the file layout.
public struct KDFParams: Codable, Equatable, Sendable {
    public static let pbkdf2SHA256 = "pbkdf2-sha256"
    public static let defaultIterations = 600_000

    public var id: String
    public var iterations: Int
    public var salt: Data

    public init(id: String = KDFParams.pbkdf2SHA256, iterations: Int = KDFParams.defaultIterations, salt: Data) {
        self.id = id
        self.iterations = iterations
        self.salt = salt
    }

    public static func random(iterations: Int = KDFParams.defaultIterations) -> KDFParams {
        KDFParams(iterations: iterations, salt: SecureRandom.bytes(32))
    }
}

public enum KDF {
    /// Derives a 256-bit key-encryption key from a passphrase.
    public static func deriveKEK(passphrase: String, params: KDFParams) throws -> SymmetricKey {
        guard params.id == KDFParams.pbkdf2SHA256 else { throw VaultError.unsupportedKDF(params.id) }
        let passBytes = Array(passphrase.utf8)
        let saltBytes = [UInt8](params.salt)
        var out = [UInt8](repeating: 0, count: 32)
        let status = passBytes.withUnsafeBufferPointer { p in
            saltBytes.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(p.baseAddress).map { $0.assumingMemoryBound(to: Int8.self) }, passBytes.count,
                    s.baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(params.iterations),
                    &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw VaultError.io("PBKDF2 failed (\(status))") }
        defer { for i in out.indices { out[i] = 0 } }
        return SymmetricKey(data: out)
    }
}

public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        let r = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(r == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }
}
