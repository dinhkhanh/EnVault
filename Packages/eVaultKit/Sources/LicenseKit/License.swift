import Foundation
import CryptoKit

/// What a license unlocks.
public enum Plan: String, Codable, Sendable, CaseIterable {
    case free
    case pro
    case team
}

/// The signed payload inside a license key. Verified offline with the
/// vendor's Ed25519 public key; no license server, no network.
public struct License: Codable, Equatable, Sendable {
    public var id: UUID
    public var email: String
    public var name: String
    public var plan: Plan
    public var issuedAt: Date
    /// Updates released after this date are not covered (nil = perpetual).
    public var updatesUntil: Date?
    /// Hard expiry (subscriptions); nil = never.
    public var expiresAt: Date?
    public var seats: Int

    public init(id: UUID = UUID(), email: String, name: String, plan: Plan, issuedAt: Date = Date(), updatesUntil: Date? = nil, expiresAt: Date? = nil, seats: Int = 1) {
        self.id = id; self.email = email; self.name = name; self.plan = plan
        self.issuedAt = issuedAt; self.updatesUntil = updatesUntil; self.expiresAt = expiresAt; self.seats = seats
    }

    public var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }

    /// Whether this license covers a build released on `date` (perpetual if `updatesUntil` is nil).
    public func coversUpdates(releasedOn date: Date) -> Bool {
        guard let u = updatesUntil else { return true }
        return date <= u
    }
}

public enum LicenseError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case badSignature
    case expired
    case revoked

    public var errorDescription: String? {
        switch self {
        case .malformed: "That doesn't look like an eVault license key."
        case .badSignature: "This license key is not valid."
        case .expired: "This license has expired."
        case .revoked: "This license key was revoked (refunded order)."
        }
    }
}

/// License key format: `EVL1.<base64url payload>.<base64url signature>`.
public enum LicenseCodec {
    static let prefix = "EVL1"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public static func encode(_ license: License, signingKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = try encoder.encode(license)
        let sig = try signingKey.signature(for: payload)
        return [prefix, base64url(payload), base64url(sig)].joined(separator: ".")
    }

    public static func decode(_ key: String, publicKey: Curve25519.Signing.PublicKey) throws -> License {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, parts[0] == prefix,
              let payload = unbase64url(String(parts[1])), let sig = unbase64url(String(parts[2])) else { throw LicenseError.malformed }
        guard publicKey.isValidSignature(sig, for: payload) else { throw LicenseError.badSignature }
        guard let license = try? decoder.decode(License.self, from: payload) else { throw LicenseError.malformed }
        if license.isExpired { throw LicenseError.expired }
        return license
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unbase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// Verifies keys against the vendor public key compiled into the app.
/// `revoked` is the list of license ids refunded so far, shipped with each release
/// (there is no activation server, so revocation rides on updates).
public struct LicenseVerifier: Sendable {
    public let publicKey: Curve25519.Signing.PublicKey
    public let revoked: Set<String>

    public init(publicKey: Curve25519.Signing.PublicKey, revoked: Set<String> = []) {
        self.publicKey = publicKey
        self.revoked = Set(revoked.map { $0.uppercased() })
    }

    /// From a base64 public key string (as printed by `evault-license keygen`).
    public init(publicKeyBase64: String, revoked: Set<String> = []) throws {
        guard let d = Data(base64Encoded: publicKeyBase64) else { throw LicenseError.malformed }
        self.init(publicKey: try Curve25519.Signing.PublicKey(rawRepresentation: d), revoked: revoked)
    }

    public func verify(_ key: String) throws -> License {
        let lic = try LicenseCodec.decode(key, publicKey: publicKey)
        if revoked.contains(lic.id.uuidString.uppercased()) { throw LicenseError.revoked }
        return lic
    }
}
