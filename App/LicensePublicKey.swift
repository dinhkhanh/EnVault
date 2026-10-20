import Foundation
import LicenseKit

/// Ed25519 public key that verifies license keys issued by `envault-license`.
/// The matching private key lives in the vendor's keychain
/// (item "dk.dinhkhanh.evault.license-signing"), never in the repo.
enum LicensePublicKey {
    static let base64 = VendorKey.licensePublicKey
}
