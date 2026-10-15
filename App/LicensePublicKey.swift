import Foundation

/// Ed25519 public key that verifies license keys issued by `evault-license`.
/// The matching private key lives in the vendor's keychain
/// (item "dk.dinhkhanh.evault.license-signing"), never in the repo.
enum LicensePublicKey {
    static let base64 = "Oh6BDufPhc5jL0Xt6jLrt+nIexZSqmbhqs4uNN0UBLc="
}
