import Testing
import Foundation
import CryptoKit
@testable import LicenseKit

@Suite struct LicenseTests {
    let key = Curve25519.Signing.PrivateKey()

    @Test func roundTrip() throws {
        let lic = License(email: "dev@example.com", name: "Dev", plan: .pro, updatesUntil: Date().addingTimeInterval(86400 * 365))
        let s = try LicenseCodec.encode(lic, signingKey: key)
        #expect(s.hasPrefix("EVL1."))
        let back = try LicenseVerifier(publicKey: key.publicKey).verify(s)
        #expect(back.id == lic.id)
        #expect(back.plan == .pro)
        #expect(back.email == "dev@example.com")
        // via base64 public key, with surrounding whitespace in the key
        let v = try LicenseVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        #expect(try v.verify("  \(s)\n").id == lic.id)
    }

    @Test func tamperingFails() throws {
        let lic = License(email: "a@b.c", name: "A", plan: .pro)
        let s = try LicenseCodec.encode(lic, signingKey: key)
        let parts = s.split(separator: ".").map(String.init)
        // Change the plan to team inside the payload.
        var json = try JSONSerialization.jsonObject(with: LicenseCodec.unbase64url(parts[1])!) as! [String: Any]
        json["plan"] = "team"
        let forged = [parts[0], LicenseCodec.base64url(try JSONSerialization.data(withJSONObject: json)), parts[2]].joined(separator: ".")
        #expect(throws: LicenseError.badSignature) { try LicenseVerifier(publicKey: key.publicKey).verify(forged) }
        #expect(throws: LicenseError.badSignature) { try LicenseVerifier(publicKey: Curve25519.Signing.PrivateKey().publicKey).verify(s) }
        #expect(throws: LicenseError.malformed) { try LicenseVerifier(publicKey: key.publicKey).verify("garbage") }
        #expect(throws: LicenseError.malformed) { try LicenseVerifier(publicKey: key.publicKey).verify("EVL0.a.b") }
    }

    @Test func expiry() throws {
        let lic = License(email: "a@b.c", name: "A", plan: .pro, expiresAt: Date().addingTimeInterval(-10))
        let s = try LicenseCodec.encode(lic, signingKey: key)
        #expect(throws: LicenseError.expired) { try LicenseVerifier(publicKey: key.publicKey).verify(s) }
    }

    @Test func entitlements() {
        let free = Entitlements.free
        #expect(!free.allows(.cloudKitSync))
        #expect(free.canAddProject(existing: 2))
        #expect(!free.canAddProject(existing: 3))
        let pro = Entitlements(plan: .pro)
        #expect(pro.allows(.cloudKitSync))
        #expect(pro.allows(.developerTools))
        #expect(!pro.allows(.teamSharing))
        #expect(pro.canAddProject(existing: 100))
        #expect(Entitlements(plan: .team).allows(.teamSharing))
    }
}
