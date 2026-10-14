import Foundation

/// Ed25519 public key that verifies license keys issued by `evault-license`.
/// The matching private key lives in the vendor's keychain
/// (item "dk.dinhkhanh.evault.license-signing"), never in the repo.
enum LicensePublicKey {
    static let base64 = "3rR8Aw9MhLHLQWrWAVqgHn5Ik5UVi9mqzdZed3hOLuI="
}
