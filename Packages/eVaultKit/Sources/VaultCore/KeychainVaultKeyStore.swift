import Foundation
import Security
import LocalAuthentication
import os

/// Caches the vault key in this Mac's Keychain so the vault can be unlocked
/// with Touch ID instead of the passphrase.
///
/// Preferred path: the data-protection keychain with a `.biometryCurrentSet`
/// access control, so the *keychain* enforces Touch ID and the item dies if
/// biometrics are re-enrolled. That path needs a real code-signing identity.
/// Fallback (ad-hoc signed dev builds, which get `errSecMissingEntitlement`):
/// a legacy keychain item, with Touch ID enforced by this app via
/// `LAContext` before the item is read.
public struct KeychainVaultKeyStore: Sendable {
    public static let service = "dk.dinhkhanh.evault.vaultkey"
    private static let log = Logger(subsystem: "dk.dinhkhanh.evault", category: "keychain")
    private static let missingEntitlement: OSStatus = -34018

    public init() {}

    public static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    private func baseQuery(_ vaultId: UUID, dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    public func save(_ key: VaultKey, vaultId: UUID) throws {
        try? remove(vaultId: vaultId)
        var cfErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.biometryCurrentSet], &cfErr) else {
            throw VaultError.biometricsUnavailable
        }
        var q = baseQuery(vaultId, dataProtection: true)
        q[kSecAttrAccessControl as String] = access
        q[kSecValueData as String] = key.data
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == Self.missingEntitlement {
            Self.log.warning("Data-protection keychain unavailable (unsigned build); using legacy keychain with app-enforced Touch ID")
            var legacy = baseQuery(vaultId, dataProtection: false)
            legacy[kSecValueData as String] = key.data
            legacy[kSecAttrLabel as String] = "eVault vault key (Touch ID)"
            status = SecItemAdd(legacy as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Self.log.error("save failed: \(status)")
            throw VaultError.keychain(status)
        }
    }

    /// Prompts Touch ID and returns the cached key, or nil if none is cached
    /// or the user cancelled.
    public func load(vaultId: UUID, reason: String = "Unlock your eVault") throws -> VaultKey? {
        let ctx = LAContext()
        ctx.localizedReason = reason
        var q = baseQuery(vaultId, dataProtection: true)
        q[kSecReturnData as String] = true
        q[kSecUseAuthenticationContext as String] = ctx
        var out: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &out)

        if status == Self.missingEntitlement {
            // Legacy path: we must enforce biometrics ourselves.
            guard hasLegacyItem(vaultId) else { return nil }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                ok = success
                sem.signal()
            }
            sem.wait()
            guard ok else { return nil }
            var legacy = baseQuery(vaultId, dataProtection: false)
            legacy[kSecReturnData as String] = true
            status = SecItemCopyMatching(legacy as CFDictionary, &out)
        }

        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == 32 else { throw VaultError.keychain(status) }
            return VaultKey(data: data)
        case errSecItemNotFound, errSecUserCanceled, errSecAuthFailed:
            return nil
        default:
            Self.log.error("load failed: \(status)")
            throw VaultError.keychain(status)
        }
    }

    public func hasCachedKey(vaultId: UUID) -> Bool {
        var q = baseQuery(vaultId, dataProtection: true)
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        return hasLegacyItem(vaultId)
    }

    private func hasLegacyItem(_ vaultId: UUID) -> Bool {
        var q = baseQuery(vaultId, dataProtection: false)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func remove(vaultId: UUID) throws {
        for dp in [true, false] {
            let status = SecItemDelete(baseQuery(vaultId, dataProtection: dp) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement else { throw VaultError.keychain(status) }
        }
    }
}
