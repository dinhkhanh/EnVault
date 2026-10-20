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
        // wrapped across lines by a mail client
        let wrapped = stride(from: 0, to: s.count, by: 60).map { i in
            String(s.dropFirst(i).prefix(60))
        }.joined(separator: "\r\n ")
        #expect(try v.verify(wrapped).id == lic.id)
        #expect(LicenseCodec.looksLikeKey(wrapped))
        #expect(!LicenseCodec.looksLikeKey(String(s.dropLast(10))))  // cut off mid-signature
        #expect(!LicenseCodec.looksLikeKey(s.components(separatedBy: ".").dropLast().joined(separator: ".")))
        #expect(!LicenseCodec.looksLikeKey("EVL1.…"))
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

    @Test func revocationAndUpdateWindow() throws {
        let lic = License(email: "a@b.c", name: "A", plan: .pro, updatesUntil: Date(timeIntervalSince1970: 1_800_000_000))
        let s = try LicenseCodec.encode(lic, signingKey: key)
        #expect(throws: LicenseError.revoked) { try LicenseVerifier(publicKey: key.publicKey, revoked: [lic.id.uuidString.lowercased()]).verify(s) }
        #expect(try LicenseVerifier(publicKey: key.publicKey, revoked: [UUID().uuidString]).verify(s).id == lic.id)
        #expect(lic.coversUpdates(releasedOn: Date(timeIntervalSince1970: 1_799_999_999)))
        #expect(!lic.coversUpdates(releasedOn: Date(timeIntervalSince1970: 1_800_000_001)))
        #expect(License(email: "a@b.c", name: "A", plan: .pro).coversUpdates(releasedOn: .distantFuture))
    }

    /// A key produced by the store Worker (store/src/license.ts) decodes here: second-precision
    /// ISO dates, sorted keys, uppercase UUID. Signed with a throwaway test key.
    @Test func workerIssuedKeyShape() throws {
        let payload = #"{"email":"e2e@example.com","id":"3137FD97-77FD-48DF-B102-224AD30294A3","issuedAt":"2026-10-14T17:17:30Z","name":"E2E Tester","plan":"pro","seats":1,"updatesUntil":"2027-10-14T17:17:30Z"}"#
        let data = Data(payload.utf8)
        let sig = try key.signature(for: data)
        let s = ["EVL1", LicenseCodec.base64url(data), LicenseCodec.base64url(sig)].joined(separator: ".")
        let lic = try LicenseVerifier(publicKey: key.publicKey).verify(s)
        #expect(lic.id.uuidString == "3137FD97-77FD-48DF-B102-224AD30294A3")
        #expect(lic.updatesUntil != nil)
        #expect(!lic.coversUpdates(releasedOn: Date(timeIntervalSince1970: 1_830_000_000))) // 2027-12-31
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

    @Test func teamLicenseStatusFollowsTheExpiry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let verifier = LicenseVerifier(publicKey: key.publicKey)
        let now = Date()
        func team(expires: Date?, plan: Plan = .team) throws -> String {
            try LicenseCodec.encode(License(email: "a@b.c", name: "A", plan: plan, expiresAt: expires, seats: 5), signingKey: key)
        }
        #expect(TeamLicenseStatus.evaluate(nil, verifier: verifier) == .missing)
        #expect(TeamLicenseStatus.evaluate(try team(expires: now.addingTimeInterval(86_400)), verifier: verifier, now: now).seats == 5)
        // Expired three days ago: grace, still 5 seats, writes allowed.
        let grace = TeamLicenseStatus.evaluate(try team(expires: now.addingTimeInterval(-3 * 86_400)), verifier: verifier, now: now)
        #expect(grace.seats == 5 && grace.allowsWrites)
        if case .grace = grace {} else { Issue.record("expected grace, got \(grace)") }
        // Expired 15 days ago: read-only, no approvals.
        let over = TeamLicenseStatus.evaluate(try team(expires: now.addingTimeInterval(-15 * 86_400)), verifier: verifier, now: now)
        #expect(!over.allowsWrites && over.seats == nil)
        // A Pro key, a forged key, a revoked key.
        if case .invalid = TeamLicenseStatus.evaluate(try team(expires: nil, plan: .pro), verifier: verifier) {} else { Issue.record("pro accepted") }
        let other = try LicenseCodec.encode(License(email: "a@b.c", name: "A", plan: .team, seats: 5), signingKey: .init())
        if case .invalid = TeamLicenseStatus.evaluate(other, verifier: verifier) {} else { Issue.record("forged accepted") }
        let k = try team(expires: nil)
        let id = try verifier.verify(k).id.uuidString
        if case .invalid = TeamLicenseStatus.evaluate(k, verifier: LicenseVerifier(publicKey: key.publicKey, revoked: [id])) {} else { Issue.record("revoked accepted") }
    }
}
