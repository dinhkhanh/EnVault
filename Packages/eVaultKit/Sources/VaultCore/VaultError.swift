import Foundation

public enum VaultError: Error, Equatable, Sendable {
    case noVaultAtLocation
    case vaultAlreadyExists
    case wrongPassphrase
    case noRecoveryKey
    case wrongRecoveryKey
    case locked
    case corruptHeader(String)
    case corruptRevision(String)
    case unsupportedFormatVersion(Int)
    case unsupportedKDF(String)
    case keychain(OSStatus)
    case biometricsUnavailable
    case io(String)
}

extension VaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noVaultAtLocation: "No vault found at that location."
        case .vaultAlreadyExists: "A vault already exists at that location."
        case .wrongPassphrase: "Wrong passphrase."
        case .noRecoveryKey: "This vault has no recovery key."
        case .wrongRecoveryKey: "That recovery key is not valid for this vault."
        case .locked: "The vault is locked."
        case .corruptHeader(let why): "Vault header is corrupt: \(why)"
        case .corruptRevision(let why): "A revision file is corrupt: \(why)"
        case .unsupportedFormatVersion(let v): "Unsupported vault format version \(v). Update eVault."
        case .unsupportedKDF(let id): "Unsupported key derivation function \(id). Update eVault."
        case .keychain(let s): "Keychain error \(s)."
        case .biometricsUnavailable: "Touch ID is not available on this Mac."
        case .io(let why): why
        }
    }
}
