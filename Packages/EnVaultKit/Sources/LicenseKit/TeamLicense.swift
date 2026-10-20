import Foundation

/// What a team vault's license allows (FR-10, FR-27): the key the owner put
/// in the vault, checked on each Mac with the vendor's public key.
public enum TeamLicenseStatus: Equatable, Sendable {
    /// No Team license in the vault yet (the owner's Mac adds its own).
    case missing
    /// Not a genuine Team key: forged, revoked or another plan.
    case invalid(String)
    case active(seats: Int, expiresAt: Date?)
    /// Past its expiry: everything works for `graceDays` more, then the vault turns read-only.
    case grace(seats: Int, readOnlyFrom: Date)
    /// Read-only for everyone until a renewal reaches the vault. Nothing is deleted.
    case readOnly(since: Date)

    public static let graceDays = 14

    public static func evaluate(_ key: String?, verifier: LicenseVerifier, now: Date = Date()) -> TeamLicenseStatus {
        guard let key else { return .missing }
        let license: License
        do { license = try verifier.verify(key, allowExpired: true) } catch { return .invalid(error.localizedDescription) }
        guard license.plan == .team else { return .invalid("That is not a Team license.") }
        guard let expires = license.expiresAt, expires < now else { return .active(seats: license.seats, expiresAt: license.expiresAt) }
        let readOnlyFrom = expires.addingTimeInterval(TimeInterval(graceDays) * 86_400)
        return now < readOnlyFrom ? .grace(seats: license.seats, readOnlyFrom: readOnlyFrom) : .readOnly(since: readOnlyFrom)
    }

    /// Seats the vault may have, while members can still be approved.
    public var seats: Int? {
        switch self { case .active(let s, _), .grace(let s, _): s; default: nil }
    }

    /// New revisions may be saved (FR-27).
    public var allowsWrites: Bool {
        switch self { case .readOnly, .invalid: false; default: true }
    }
}
