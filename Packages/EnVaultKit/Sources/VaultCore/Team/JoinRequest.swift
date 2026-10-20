import Foundation
import CryptoKit

/// Someone asking to join a team vault (FR-7), stored as
/// `identities/<memberId>/<ulid>.json`. Signed by the requester, so nobody can
/// ask on another person's behalf. The identity is unnamed; the name they gave
/// is sealed to each owner and admin at the time, so only those can read it
/// (NFR-13). The admin still compares the safety code before approving (FR-8).
public struct JoinRequest: Codable, Equatable, Sendable {
    public var id: ULID
    public var identity: PublicIdentity
    /// The requester's name, one HPKE copy per owner or admin (`member` = who can open it).
    public var names: [KeyWrap]
    public var signature: Data

    public static func signed(by person: UserIdentity, managers: [PublicIdentity], vaultId: UUID, id: ULID = ULID()) throws -> JoinRequest {
        let names = try managers.map { m in
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: m.agreementKey)
            var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: TeamKeys.suite,
                                         info: nameInfo(vaultId: vaultId, request: id, requester: person.id, manager: m.id))
            let ct = try sender.seal(Data(person.name.utf8))
            return KeyWrap(member: m.id, encapsulatedKey: sender.encapsulatedKey, ciphertext: ct)
        }
        var r = JoinRequest(id: id, identity: try person.publicIdentity().unnamed, names: names, signature: Data())
        r.signature = try person.signingKey.signature(for: r.signedBytes(vaultId: vaultId))
        return r
    }

    func signedBytes(vaultId: UUID) -> Data {
        var c = CanonicalBytes("envault-join-request:1")
        c.add(vaultId)
        c.add(id)
        c.add(identity.signedBytes)
        c.add(identity.signature)
        for n in names.sorted(by: { $0.member.uuidString < $1.member.uuidString }) {
            c.add(n.member); c.add(n.encapsulatedKey); c.add(n.ciphertext)
        }
        return c.data
    }

    static func nameInfo(vaultId: UUID, request: ULID, requester: UUID, manager: UUID) -> Data {
        var c = CanonicalBytes("envault-join-name:1")
        c.add(vaultId); c.add(request); c.add(requester); c.add(manager)
        return c.data
    }

    /// Self-signed, unnamed and bound to this vault.
    public func isValid(vaultId: UUID) -> Bool {
        guard identity.isValid, identity.name.isEmpty,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: identity.signingKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes(vaultId: vaultId))
    }

    /// The requester's name, if `manager` is one of the people it was sealed to.
    public func name(for manager: UserIdentity, vaultId: UUID) -> String? {
        guard let copy = names.first(where: { $0.member == manager.id }),
              var r = try? HPKE.Recipient(privateKey: manager.agreementKey, ciphersuite: TeamKeys.suite,
                                          info: Self.nameInfo(vaultId: vaultId, request: id, requester: identity.id, manager: manager.id),
                                          encapsulatedKey: copy.encapsulatedKey),
              let plain = try? r.open(copy.ciphertext) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> JoinRequest {
        do { return try JSONDecoder().decode(JoinRequest.self, from: data) } catch {
            throw VaultError.corruptRevision("join request: \(error)")
        }
    }
}

/// A join request as an admin sees it.
public struct PendingMember: Equatable, Sendable, Identifiable {
    public var id: UUID { identity.id }
    public var request: ULID
    public var identity: PublicIdentity
    /// The name they gave; nil when it was not sealed to this admin.
    public var name: String?
    public var safetyCode: String { identity.safetyCode }
    public var requestedAt: Date { request.timestamp }
}
