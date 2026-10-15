import Foundation

/// Ed25519 public key that verifies license keys issued by `evault-license`.
/// The matching private key lives in the vendor's keychain
/// (item "dk.dinhkhanh.evault.license-signing"), never in the repo.
enum LicensePublicKey {
    static let base64 = "LR48ZIUF9ljixUBXir7O99t37u+/fRkIiGBPkDpaTP4="
}
