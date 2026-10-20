import Foundation

/// The file an admin sends someone to invite them to a folder-mode team
/// vault (FR-6). It carries the owner's signing key, so the invitee's Mac
/// checks the shared folder against it instead of trusting the first header
/// it finds, and the id of the signed `invite` event that offers the role.
public struct TeamInvite: Codable, Equatable, Sendable {
    public static let fileExtension = "envault-invite"

    public var format = 1
    public var vaultId: UUID
    /// `TeamHeader.owner.signingKey`.
    public var ownerKey: Data
    public var invite: ULID
    /// The vault's name, for the invitee to recognise it. The file travels
    /// privately from the admin to them.
    public var title: String?

    public init(vaultId: UUID, ownerKey: Data, invite: ULID, title: String?) {
        self.vaultId = vaultId; self.ownerKey = ownerKey; self.invite = invite; self.title = title
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> TeamInvite {
        guard let i = try? JSONDecoder().decode(TeamInvite.self, from: data), i.format == 1 else {
            throw VaultError.io("That isn't an EnVault team invitation.")
        }
        return i
    }

    /// Whether the folder holds the vault this invitation is for, owned by
    /// the same person, and the invitation is still open.
    public func check(header: TeamHeader, state: TeamState, now: Date = Date()) throws {
        guard header.vaultId == vaultId, header.owner.signingKey == ownerKey else {
            throw VaultError.corruptHeader("this folder holds a different team vault from the one in the invitation")
        }
        guard let offer = state.invites[invite] else {
            throw VaultError.notPermitted("The folder doesn't have this invitation yet. Wait for it to finish syncing, then try again.")
        }
        guard offer.expiresAt > now else {
            throw VaultError.notPermitted("This invitation has lapsed. Ask for a new one.")
        }
    }
}
