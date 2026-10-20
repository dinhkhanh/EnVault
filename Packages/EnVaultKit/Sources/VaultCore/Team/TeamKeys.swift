import Foundation
import CryptoKit

extension ULID {
    /// Sorts before every real id: the owner's role "from the start".
    public static let zero = ULID(string: "00000000000000000000000000")!
}

/// One member's copy of an epoch's team key, stored as
/// `keys/<epoch>/<member>.json`. HPKE to the member's X25519 key; anyone with
/// the key may write one (an admin approving a new member), and the recipient
/// checks the result against the epoch's signed commitment, so a wrap of any
/// other key is rejected.
public struct KeyWrap: Codable, Equatable, Sendable {
    public var member: UUID
    public var encapsulatedKey: Data
    public var ciphertext: Data

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> KeyWrap {
        do { return try JSONDecoder().decode(KeyWrap.self, from: data) } catch { throw VaultError.corruptRevision("key wrap: \(error)") }
    }
}

/// A member's display name, AES-GCM under one epoch's key (NFR-13).
public struct SealedName: Codable, Equatable, Sendable {
    public var epoch: ULID
    public var box: Data
}

/// An older epoch's key sealed under a newer one, stored as
/// `keys/<newer>/prev-<older>.json`. Whoever holds the newer key can follow
/// the links back and read revisions from before it, so a newcomer sees the
/// vault's history (FR-16). Each key is checked against its epoch's commitment.
public struct KeyLink: Codable, Equatable, Sendable {
    public var newer: ULID
    public var older: ULID
    public var box: Data

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> KeyLink {
        do { return try JSONDecoder().decode(KeyLink.self, from: data) } catch { throw VaultError.corruptRevision("key link: \(error)") }
    }
}

/// Team keys: one random 256-bit AES key per epoch (NFR-2, NFR-3).
public enum TeamKeys {
    /// X25519, HKDF-SHA256, AES-256-GCM.
    static let suite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// What a `rotate` event signs: binds the key to the vault and the epoch.
    public static func commitment(to key: SymmetricKey, vaultId: UUID, epoch: ULID) -> Data {
        var c = CanonicalBytes("envault-epoch-key:1")
        c.add(vaultId)
        c.add(epoch)
        c.add(key.withUnsafeBytes { Data($0) })
        return Data(SHA256.hash(data: c.data))
    }

    static func info(vaultId: UUID, epoch: ULID, member: UUID) -> Data {
        var c = CanonicalBytes("envault-team-key:1")
        c.add(vaultId)
        c.add(epoch)
        c.add(member)
        return c.data
    }

    public static func wrap(_ key: SymmetricKey, for member: PublicIdentity, vaultId: UUID, epoch: ULID) throws -> KeyWrap {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: member.agreementKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info(vaultId: vaultId, epoch: epoch, member: member.id))
        let ct = try sender.seal(key.withUnsafeBytes { Data($0) })
        return KeyWrap(member: member.id, encapsulatedKey: sender.encapsulatedKey, ciphertext: ct)
    }

    /// Opens the wrap meant for `identity` and checks it against the epoch's commitment.
    public static func unwrap(_ wrap: KeyWrap, identity: UserIdentity, vaultId: UUID, epoch: TeamEpoch) throws -> SymmetricKey {
        guard wrap.member == identity.id else { throw VaultError.corruptRevision("key wrap is for someone else") }
        let raw: Data
        do {
            var r = try HPKE.Recipient(privateKey: identity.agreementKey, ciphersuite: suite,
                                       info: info(vaultId: vaultId, epoch: epoch.id, member: identity.id),
                                       encapsulatedKey: wrap.encapsulatedKey)
            raw = try r.open(wrap.ciphertext)
        } catch {
            throw VaultError.corruptRevision("key wrap does not open")
        }
        let key = SymmetricKey(data: raw)
        guard raw.count == 32, commitment(to: key, vaultId: vaultId, epoch: epoch.id) == epoch.keyCommitment else {
            throw VaultError.corruptRevision("key wrap holds a key the epoch did not sign")
        }
        return key
    }

    static func linkAAD(vaultId: UUID, newer: ULID, older: ULID) -> Data {
        var c = CanonicalBytes("envault-epoch-link:1")
        c.add(vaultId); c.add(newer); c.add(older)
        return c.data
    }

    public static func link(_ olderKey: SymmetricKey, older: ULID, under newerKey: SymmetricKey, newer: ULID, vaultId: UUID) throws -> KeyLink {
        let box = try AES.GCM.seal(olderKey.withUnsafeBytes { Data($0) }, using: newerKey,
                                   authenticating: linkAAD(vaultId: vaultId, newer: newer, older: older)).combined!
        return KeyLink(newer: newer, older: older, box: box)
    }

    /// Opens a link with the newer epoch's key and checks the result against the older epoch.
    public static func open(_ link: KeyLink, with newerKey: SymmetricKey, newer: ULID, older: TeamEpoch, vaultId: UUID) throws -> SymmetricKey {
        guard link.older == older.id, link.newer == newer else { throw VaultError.corruptRevision("key link is for another epoch") }
        let raw: Data
        do {
            raw = try AES.GCM.open(try AES.GCM.SealedBox(combined: link.box), using: newerKey,
                                   authenticating: linkAAD(vaultId: vaultId, newer: link.newer, older: link.older))
        } catch {
            throw VaultError.corruptRevision("key link does not open")
        }
        let key = SymmetricKey(data: raw)
        guard raw.count == 32, commitment(to: key, vaultId: vaultId, epoch: older.id) == older.keyCommitment else {
            throw VaultError.corruptRevision("key link holds a key the epoch did not sign")
        }
        return key
    }

    static func nameAAD(vaultId: UUID, member: UUID, epoch: ULID) -> Data {
        var c = CanonicalBytes("envault-member-name:1")
        c.add(vaultId); c.add(member); c.add(epoch)
        return c.data
    }

    public static func seal(name: String, member: UUID, vaultId: UUID, epoch: ULID, key: SymmetricKey) throws -> SealedName {
        let box = try AES.GCM.seal(Data(name.utf8), using: key, authenticating: nameAAD(vaultId: vaultId, member: member, epoch: epoch)).combined!
        return SealedName(epoch: epoch, box: box)
    }

    public static func open(_ name: SealedName, member: UUID, vaultId: UUID, key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: name.box),
              let plain = try? AES.GCM.open(box, using: key, authenticating: nameAAD(vaultId: vaultId, member: member, epoch: name.epoch)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

/// A team vault revision file: `"EVT1"` + JSON envelope. The payload is
/// AES-256-GCM under an epoch key; the AAD binds vault, scope, owner,
/// revision, epoch and author; the author signs AAD + ciphertext (FR-16, FR-17).
public enum TeamRevisionFile {
    static let magic = Data("EVT1".utf8)

    struct Envelope: Codable {
        var epoch: ULID
        var author: UUID
        var box: Data
        var signature: Data
    }

    /// The epoch a revision file is sealed under, read without opening it.
    public static func epoch(of data: Data) -> ULID? {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data.dropFirst(magic.count)))?.epoch
    }

    /// Who signed a revision file, as it claims, read without opening it.
    public static func author(of data: Data) -> UUID? {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data.dropFirst(magic.count)))?.author
    }

    static func aad(vaultId: UUID, scope: RevisionFile.Scope, ownerId: UUID, revisionId: ULID, epoch: ULID, author: UUID) -> Data {
        var c = CanonicalBytes("envault-team-rev:1")
        c.add(vaultId); c.add(scope.rawValue); c.add(ownerId); c.add(revisionId); c.add(epoch); c.add(author)
        return c.data
    }

    public static func encode<T: Encodable>(_ value: T, vaultId: UUID, scope: RevisionFile.Scope, ownerId: UUID, revisionId: ULID,
                                            epoch: ULID, key: SymmetricKey, author: UserIdentity) throws -> Data {
        let plain = try RevisionFile.encoder.encode(value)
        let a = aad(vaultId: vaultId, scope: scope, ownerId: ownerId, revisionId: revisionId, epoch: epoch, author: author.id)
        let box = try AES.GCM.seal(plain, using: key, authenticating: a).combined!
        let sig = try author.signingKey.signature(for: a + box)
        return magic + (try JSONEncoder().encode(Envelope(epoch: epoch, author: author.id, box: box, signature: sig)))
    }

    /// Opens a revision and checks its author: signed by them, and their role
    /// allowed writing as of this revision's id. Returns the value and author.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, vaultId: UUID, scope: RevisionFile.Scope, ownerId: UUID,
                                            revisionId: ULID, state: TeamState, keys: [ULID: SymmetricKey]) throws -> (value: T, author: UUID) {
        guard data.count > magic.count, data.prefix(magic.count) == magic,
              let env = try? JSONDecoder().decode(Envelope.self, from: data.dropFirst(magic.count)) else {
            throw VaultError.corruptRevision("bad team revision \(revisionId)")
        }
        guard let author = state.everyone[env.author],
              let signer = try? Curve25519.Signing.PublicKey(rawRepresentation: author.signingKey) else {
            throw VaultError.corruptRevision("\(revisionId): unknown author")
        }
        let a = aad(vaultId: vaultId, scope: scope, ownerId: ownerId, revisionId: revisionId, epoch: env.epoch, author: env.author)
        guard signer.isValidSignature(env.signature, for: a + env.box) else {
            throw VaultError.corruptRevision("\(revisionId): bad author signature")
        }
        guard state.role(of: env.author, at: revisionId)?.canWrite == true else {
            throw VaultError.corruptRevision("\(revisionId): author could not write then")
        }
        // Nobody writes under a key before it exists: a revision dated well before
        // its epoch was backdated (an hour allows for clocks that disagree).
        guard revisionId.timestamp >= env.epoch.timestamp.addingTimeInterval(-3600) else {
            throw VaultError.corruptRevision("\(revisionId): dated before its key existed")
        }
        guard let key = keys[env.epoch] else { throw VaultError.corruptRevision("\(revisionId): no key for epoch \(env.epoch)") }
        let plain: Data
        do {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: env.box), using: key, authenticating: a)
        } catch {
            throw VaultError.corruptRevision("authentication failed for \(revisionId)")
        }
        do { return (try RevisionFile.decoder.decode(type, from: plain), env.author) } catch {
            throw VaultError.corruptRevision("json: \(error)")
        }
    }
}
