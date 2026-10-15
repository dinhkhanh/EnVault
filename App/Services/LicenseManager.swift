import SwiftUI
import LicenseKit

/// Holds the current license and answers feature questions for the UI.
/// The key is verified offline against `LicensePublicKey`; nothing is sent anywhere.
@MainActor
@Observable
final class LicenseManager {
    private static let defaultsKey = "dk.dinhkhanh.evault.licenseKey"
    static let purchaseURL = URL(string: "https://dinhkhanh.github.io/eVault/#pricing")!
    static let resendKeyURL = URL(string: "https://store.evault.dinhkhanh.dk/resend")!

    private(set) var entitlements: Entitlements = .free
    private(set) var licenseKey: String?
    var lastError: String?
    /// Set when a stored key is valid but does not cover this release (updates window passed).
    private(set) var updatesNotice: String?
    /// Which feature triggered the upgrade sheet, if any.
    var upgradePrompt: Feature?

    private let verifier = try? LicenseVerifier(publicKeyBase64: LicensePublicKey.base64, revoked: RevokedLicenses.ids)

    /// Release date of this build, from Info.plist `EVReleaseDate` (set in project.yml).
    static let releaseDate: Date = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        // YAML may hand XcodeGen a date object; accept "yyyy-MM-dd" with anything after it.
        if let s = Bundle.main.object(forInfoDictionaryKey: "EVReleaseDate") as? String, let d = f.date(from: String(s.prefix(10))) { return d }
        if let d = Bundle.main.object(forInfoDictionaryKey: "EVReleaseDate") as? Date { return d }
        // Unknown release date: never penalise a valid key for it.
        return .distantPast
    }()

    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "pro") { entitlements = Entitlements(plan: .pro); return }
        #endif
        if let k = UserDefaults.standard.string(forKey: Self.defaultsKey) { _ = apply(k, persist: false) }
    }

    var plan: Plan { entitlements.plan }
    var license: License? { entitlements.license }

    func allows(_ f: Feature) -> Bool { entitlements.allows(f) }

    /// Returns true if allowed; otherwise opens the upgrade prompt and returns false.
    func require(_ f: Feature) -> Bool {
        if allows(f) { return true }
        upgradePrompt = f
        return false
    }

    func canAddProject(existing: Int) -> Bool {
        if entitlements.canAddProject(existing: existing) { return true }
        upgradePrompt = .unlimitedProjects
        return false
    }

    @discardableResult
    func apply(_ key: String, persist: Bool = true) -> Bool {
        guard let verifier else { lastError = "License verification is not configured in this build."; return false }
        do {
            let lic = try verifier.verify(key)
            licenseKey = LicenseCodec.normalize(key)
            lastError = nil
            if persist { UserDefaults.standard.set(licenseKey, forKey: Self.defaultsKey) }
            if lic.coversUpdates(releasedOn: Self.releaseDate) {
                entitlements = Entitlements(plan: lic.plan, license: lic)
                updatesNotice = nil
            } else {
                // The key stays stored (older versions still honour it); this build runs as Free.
                entitlements = Entitlements(plan: .free, license: lic)
                let f = DateFormatter(); f.dateStyle = .medium
                updatesNotice = "This license covers updates until \(f.string(from: lic.updatesUntil ?? .distantPast)); this version was released on \(f.string(from: Self.releaseDate)). Renew to keep Pro on new versions, or use a version released before that date."
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func remove() {
        entitlements = .free
        licenseKey = nil
        updatesNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
