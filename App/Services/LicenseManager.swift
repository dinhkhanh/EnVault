import SwiftUI
import LicenseKit

/// Holds the current license and answers feature questions for the UI.
/// The key is verified offline against `LicensePublicKey`; nothing is sent anywhere.
@MainActor
@Observable
final class LicenseManager {
    private static let defaultsKey = "dk.dinhkhanh.evault.licenseKey"
    static let purchaseURL = URL(string: "https://evault.dinhkhanh.dk/#pricing")!

    private(set) var entitlements: Entitlements = .free
    private(set) var licenseKey: String?
    var lastError: String?
    /// Which feature triggered the upgrade sheet, if any.
    var upgradePrompt: Feature?

    private let verifier = try? LicenseVerifier(publicKeyBase64: LicensePublicKey.base64)

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
            entitlements = Entitlements(plan: lic.plan, license: lic)
            licenseKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = nil
            if persist { UserDefaults.standard.set(licenseKey, forKey: Self.defaultsKey) }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func remove() {
        entitlements = .free
        licenseKey = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }
}
