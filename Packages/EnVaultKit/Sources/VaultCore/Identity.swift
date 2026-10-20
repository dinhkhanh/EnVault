import Foundation
import CryptoKit

/// A person's Team identity (FR-1): an X25519 key pair for receiving wrapped
/// team keys and an Ed25519 key pair for signing what they write. The private
/// halves live in their personal vault, so the identity follows them to every Mac.
public struct UserIdentity: Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey

    /// What other people see: public keys and the name, signed by the signing key.
    public func publicIdentity() throws -> PublicIdentity {
        var p = PublicIdentity(id: id, name: name,
                               agreementKey: agreementKey.publicKey.rawRepresentation,
                               signingKey: signingKey.publicKey.rawRepresentation,
                               signature: Data())
        p.signature = try signingKey.signature(for: p.signedBytes)
        return p
    }

    public var safetyCode: String {
        SafetyCode.code(agreementKey: agreementKey.publicKey.rawRepresentation, signingKey: signingKey.publicKey.rawRepresentation)
    }
}

/// The shareable half of a `UserIdentity`. Plain data, self-signed.
public struct PublicIdentity: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Raw 32-byte X25519 public key.
    public var agreementKey: Data
    /// Raw 32-byte Ed25519 public key.
    public var signingKey: Data
    /// Ed25519 signature by `signingKey` over `signedBytes`.
    public var signature: Data

    /// Length-prefixed fields under a versioned label, so no two different
    /// identities serialise to the same bytes.
    var signedBytes: Data {
        var c = CanonicalBytes("envault-identity:1")
        c.add(id)
        c.add(agreementKey)
        c.add(signingKey)
        c.add(name)
        return c.data
    }

    /// The keys are well formed and the signature is the signing key's own.
    public var isValid: Bool {
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)) != nil,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    public var safetyCode: String { SafetyCode.code(agreementKey: agreementKey, signingKey: signingKey) }
}

/// The code two people read to each other before an admin approves a member (FR-2).
///
/// SHA-512 over both public keys under a versioned label; six 5-byte chunks,
/// each reduced mod 100 000, give six groups of five digits (about 100 bits).
/// The name is not part of it, so renaming keeps the code.
public enum SafetyCode {
    public static func code(agreementKey: Data, signingKey: Data) -> String {
        var input = Data("envault-safety-code:1".utf8)
        input.append(agreementKey)
        input.append(signingKey)
        let digest = Array(SHA512.hash(data: input))
        return (0..<6).map { group in
            let chunk = digest[(group * 5)..<(group * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let n = String(chunk % 100_000)
            return String(repeating: "0", count: 5 - n.count) + n
        }.joined(separator: " ")
    }
}

/// One encrypted revision of the identity, stored in the personal vault.
struct IdentityRevision: Codable, Sendable {
    var id: ULID
    var identityId: UUID
    var name: String
    var createdAt: Date
    var agreementKey: Data
    var signingKey: Data

    func identity() throws -> UserIdentity {
        UserIdentity(id: identityId, name: name, createdAt: createdAt,
                     agreementKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementKey),
                     signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey))
    }
}

public enum IdentityLayout {
    /// The identity lives under `projects/<namespace>/identity/<identityId>/<ulid>.evr`.
    /// Inside `projects/` on purpose: releases up to 0.7.1 sync only `projects/**/*.evr`
    /// and delete anything else they pulled, while their `VaultStore` reads only
    /// `meta/` and `items/` and so never shows this folder as a project.
    public static let namespace = UUID(uuidString: "00000000-0000-4000-8000-1de9717e0001")!
}
