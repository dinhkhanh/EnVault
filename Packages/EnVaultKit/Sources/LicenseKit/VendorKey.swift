/// The vendor's Ed25519 public key that verifies license keys issued by
/// `envault-license` and the store. In the package so the app and the
/// `envault` command check the same key (a team vault's license, FR-27).
/// The private key lives in the vendor's keychain, never in the repo.
public enum VendorKey {
    public static let licensePublicKey = "LR48ZIUF9ljixUBXir7O99t37u+/fRkIiGBPkDpaTP4="
}
