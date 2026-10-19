import Foundation
import CloudKit

/// A vault zone someone else owns and shares with this user.
public struct SharedVaultRef: Hashable, Sendable {
    public var vaultId: UUID
    /// The owner's user record name; part of the zone id in the shared database.
    public var ownerName: String
    public init(vaultId: UUID, ownerName: String) { self.vaultId = vaultId; self.ownerName = ownerName }
}

/// One person on a vault's share, as CloudKit reports them.
public struct VaultShareParticipant: Hashable, Sendable {
    public enum Status: String, Sendable { case pending, accepted, removed, unknown }
    public var name: String?
    public var email: String?
    public var userRecordName: String?
    public var isOwner: Bool
    public var canWrite: Bool
    public var status: Status

    public var displayName: String { name ?? email ?? userRecordName ?? "unknown participant" }

    /// The same person on a freshly fetched share. The user record id is stable;
    /// the lookup email can be missing after acceptance or differ in case.
    func matches(_ p: CKShare.Participant) -> Bool {
        if let mine = userRecordName, let theirs = p.userIdentity.userRecordID?.recordName { return mine == theirs }
        guard let mine = email, let theirs = p.userIdentity.lookupInfo?.emailAddress else { return false }
        return mine.caseInsensitiveCompare(theirs) == .orderedSame
    }
}

public struct VaultShareInfo: Sendable {
    public var url: URL?
    public var participants: [VaultShareParticipant]
}

/// Zone-wide CloudKit sharing of a vault's `vault-<id>` zone (Team phase 0 spike).
///
/// The owner shares the zone from the private database; participants then see
/// it in their shared database and sync it with `CloudKitTransport(scope: .shared)`.
/// Everything shared is ciphertext, exactly as in the owner's own zone.
public struct CloudKitSharing: @unchecked Sendable {
    private let container: CKContainer
    private var db: CKDatabase { container.privateCloudDatabase }

    public init(containerIdentifier: String = CloudKitAvailability.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    private static func shareID(_ vaultId: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: CloudKitTransport.zoneID(vaultId))
    }

    // MARK: Owner

    /// The vault's share, or nil when it isn't shared.
    public func share(of vaultId: UUID) async throws -> CKShare? {
        do {
            return try await db.record(for: Self.shareID(vaultId)) as? CKShare
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        } catch {
            throw CloudKitTransport.map(error)
        }
    }

    /// Fetches the vault's share, creating it (invite-only, no public link) if needed.
    @discardableResult
    public func shareVault(_ vaultId: UUID, title: String) async throws -> VaultShareInfo {
        if let existing = try await share(of: vaultId) { return Self.info(existing) }
        let share = CKShare(recordZoneID: CloudKitTransport.zoneID(vaultId))
        share[CKShare.SystemFieldKey.title] = title as NSString
        share.publicPermission = .none
        return Self.info(try await save(share))
    }

    public func info(of vaultId: UUID) async throws -> VaultShareInfo? {
        try await share(of: vaultId).map(Self.info)
    }

    /// Adds someone by the email address of their Apple ID. They get the share
    /// link from the owner and accept it in EnVault.
    public func addParticipant(email: String, canWrite: Bool, to vaultId: UUID) async throws -> VaultShareInfo {
        guard let share = try await share(of: vaultId) else { throw CloudTransportError.other("The vault is not shared.") }
        let p: CKShare.Participant
        do { p = try await container.shareParticipant(forEmailAddress: email) } catch { throw CloudKitTransport.map(error) }
        p.permission = canWrite ? .readWrite : .readOnly
        p.role = .privateUser
        share.addParticipant(p)
        return Self.info(try await save(share))
    }

    public func setPermission(of person: VaultShareParticipant, canWrite: Bool, on vaultId: UUID) async throws -> VaultShareInfo {
        guard let share = try await share(of: vaultId) else { throw CloudTransportError.other("The vault is not shared.") }
        guard let p = share.participants.first(where: { person.matches($0) }) else {
            throw CloudTransportError.other("\(person.displayName) is not on the share.")
        }
        p.permission = canWrite ? .readWrite : .readOnly
        return Self.info(try await save(share))
    }

    public func removeParticipant(_ person: VaultShareParticipant, from vaultId: UUID) async throws -> VaultShareInfo {
        guard let share = try await share(of: vaultId) else { throw CloudTransportError.other("The vault is not shared.") }
        guard let p = share.participants.first(where: { person.matches($0) }) else {
            throw CloudTransportError.other("\(person.displayName) is not on the share.")
        }
        share.removeParticipant(p)
        return Self.info(try await save(share))
    }

    /// Deletes the share: every participant loses the zone. The owner's data stays.
    public func stopSharing(_ vaultId: UUID) async throws {
        let id = Self.shareID(vaultId)
        do {
            // Per-record failures come back in deleteResults, not as a thrown error.
            let r = try await db.modifyRecords(saving: [], deleting: [id])
            try r.deleteResults[id]?.get()
        } catch let e as CKError where e.code == .unknownItem {
            return
        } catch {
            throw CloudKitTransport.map(error)
        }
    }

    private func save(_ share: CKShare) async throws -> CKShare {
        do {
            let r = try await db.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
            guard let saved = try r.saveResults[share.recordID]?.get() as? CKShare else {
                throw CloudTransportError.other("CloudKit did not return the saved share.")
            }
            return saved
        } catch let e as CloudTransportError {
            throw e
        } catch {
            throw CloudKitTransport.map(error)
        }
    }

    // MARK: Participant

    /// Accepts a share link someone sent (pasted, or opened from Mail/Messages).
    public func accept(url: URL) async throws -> SharedVaultRef {
        let metadata: CKShare.Metadata
        do { metadata = try await container.shareMetadata(for: url) } catch { throw CloudKitTransport.map(error) }
        return try await accept(metadata)
    }

    public func accept(_ metadata: CKShare.Metadata) async throws -> SharedVaultRef {
        guard let ref = Self.ref(metadata.share.recordID.zoneID),
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare else {
            throw CloudTransportError.other("That link is not an EnVault vault share.")
        }
        if metadata.participantStatus != .accepted {
            do { _ = try await container.accept(metadata) } catch { throw CloudKitTransport.map(error) }
        }
        return ref
    }

    /// Vaults other users share with this one (accepted shares only).
    public func sharedVaults() async throws -> [SharedVaultRef] {
        do {
            return try await container.sharedCloudDatabase.allRecordZones().compactMap { Self.ref($0.zoneID) }
        } catch {
            throw CloudKitTransport.map(error)
        }
    }

    /// Leaves a shared vault: deleting the zone from the shared database removes this user from the share.
    public func leave(_ ref: SharedVaultRef) async throws {
        let zone = CloudKitTransport.zoneID(ref.vaultId, ownerName: ref.ownerName)
        do {
            let r = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zone])
            try r.deleteResults[zone]?.get()
        } catch let e as CKError where e.code == .zoneNotFound {
            return
        } catch {
            throw CloudKitTransport.map(error)
        }
    }

    public func transport(for ref: SharedVaultRef) -> CloudKitTransport {
        CloudKitTransport(containerIdentifier: container.containerIdentifier ?? CloudKitAvailability.containerIdentifier,
                          scope: .shared(ownerName: ref.ownerName))
    }

    // MARK: Mapping

    private static func ref(_ zoneID: CKRecordZone.ID) -> SharedVaultRef? {
        CloudKitTransport.vaultId(zoneName: zoneID.zoneName).map { SharedVaultRef(vaultId: $0, ownerName: zoneID.ownerName) }
    }

    static func info(_ share: CKShare) -> VaultShareInfo {
        let people = share.participants.map { p -> VaultShareParticipant in
            let status: VaultShareParticipant.Status = switch p.acceptanceStatus {
            case .pending: .pending
            case .accepted: .accepted
            case .removed: .removed
            default: .unknown
            }
            let name = p.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            return VaultShareParticipant(name: name, email: p.userIdentity.lookupInfo?.emailAddress,
                                         userRecordName: p.userIdentity.userRecordID?.recordName,
                                         isOwner: p.role == .owner, canWrite: p.permission == .readWrite, status: status)
        }
        return VaultShareInfo(url: share.url, participants: people)
    }
}
