import Foundation
import Security
import LocalAuthentication

/// Caches the vault key in this Mac's Keychain so the vault can be unlocked
/// with Touch ID instead of the passphrase. The item is device-only and is
/// invalidated when the enrolled biometrics change.
public struct KeychainVaultKeyStore: Sendable {
    public static let service = "dk.dinhkhanh.evault.vaultkey"

    public init() {}

    public static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    public func save(_ key: VaultKey, vaultId: UUID) throws {
        try? remove(vaultId: vaultId)
        var cfErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.biometryCurrentSet], &cfErr) else {
            throw VaultError.biometricsUnavailable
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: key.data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    /// Prompts Touch ID and returns the cached key, or nil if none is cached.
    public func load(vaultId: UUID, reason: String = "Unlock your eVault") throws -> VaultKey? {
        let ctx = LAContext()
        ctx.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: ctx,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == 32 else { throw VaultError.keychain(status) }
            return VaultKey(data: data)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            return nil
        default:
            throw VaultError.keychain(status)
        }
    }

    public func hasCachedKey(vaultId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func remove(vaultId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: vaultId.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}
