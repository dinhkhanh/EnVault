import Foundation
import CloudKit
import Security

/// Whether this build carries the iCloud entitlement (signed configurations only).
public enum CloudKitAvailability {
    public static let containerIdentifier = "iCloud." + (Bundle.main.bundleIdentifier ?? "dk.dinhkhanh.envault")

    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        guard let services = value as? [String] else { return false }
        return services.contains("CloudKit")
    }

    /// Whether this build talks to the Production CloudKit environment. Exported
    /// Developer ID builds carry the environment entitlement; development-signed
    /// builds (Debug-iCloud) have none and use Development.
    public static var isProduction: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil)
        return (value as? String) == "Production"
    }
}

/// `CloudVaultTransport` on the user's private CloudKit database, or (scope
/// `.shared`) on a vault zone another user shares with this one.
///
/// Layout: one custom record zone per vault (`vault-<uuid>`), one record of
/// type `VaultFile` per file. Record name = path with `/` replaced by `|`.
/// Small files live in a `data` field, large ones in an `asset`.
/// Incremental sync uses zone change tokens, so no queries or indexes are
/// needed and the Development schema is created just-in-time.
public struct CloudKitTransport: CloudVaultTransport, @unchecked Sendable {
    public static let recordType = "VaultFile"
    static let inlineLimit = 900_000

    /// Whose zones this transport reads and writes.
    public enum Scope: Sendable, Equatable {
        /// Zones this user owns, in the private database.
        case `private`
        /// Zones owned by `ownerName` (a user record name) and shared with this user.
        case shared(ownerName: String)
    }

    private let container: CKContainer
    public let scope: Scope
    private var db: CKDatabase {
        switch scope {
        case .private: container.privateCloudDatabase
        case .shared: container.sharedCloudDatabase
        }
    }
    private var ownerName: String {
        switch scope {
        case .private: CKCurrentUserDefaultName
        case .shared(let owner): owner
        }
    }

    public init(containerIdentifier: String = CloudKitAvailability.containerIdentifier, scope: Scope = .private) {
        container = CKContainer(identifier: containerIdentifier)
        self.scope = scope
    }

    public func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }

    static func zoneName(_ vaultId: UUID) -> String { "vault-\(vaultId.uuidString)" }
    static func vaultId(zoneName n: String) -> UUID? {
        n.hasPrefix("vault-") ? UUID(uuidString: String(n.dropFirst(6))) : nil
    }
    static func zoneID(_ vaultId: UUID, ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(vaultId), ownerName: ownerName)
    }
    private func zoneID(_ vaultId: UUID) -> CKRecordZone.ID { Self.zoneID(vaultId, ownerName: ownerName) }
    private func recordID(path: String, vaultId: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName(path), zoneID: zoneID(vaultId))
    }
    static func recordName(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "|") }
    /// Whether a fetched record named `name` may stand for `path`: a record named one thing
    /// that claims another's path could pass as that file and its uploader. Checked in this
    /// direction because mapping "|" back to "/" also turns a name containing "/" into the path.
    static func isRecordName(_ name: String, of path: String) -> Bool {
        !path.contains("|") && name == recordName(path)
    }

    /// Private scope: creates the zone. Shared scope: only the owner can create
    /// zones, so this checks the shared zone is still there.
    public func ensureVault(_ vaultId: UUID) async throws {
        switch scope {
        case .private:
            let zone = CKRecordZone(zoneID: zoneID(vaultId))
            _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
        case .shared:
            do { _ = try await db.recordZone(for: zoneID(vaultId)) } catch { throw Self.map(error) }
        }
    }

    public func subscribe(_ vaultId: UUID) async throws {
        // One database subscription covers every zone shared with this user.
        let id = scope == .private ? "envault-\(vaultId.uuidString)" : "envault-shared"
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do { _ = try await db.save(sub) } catch let e as CKError where e.code == .serverRejectedRequest { /* exists */ }
    }

    public func upload(_ files: [CloudFile], vaultId: UUID, overwrite: Bool) async throws {
        var tempFiles: [URL] = []
        defer { for t in tempFiles { try? FileManager.default.removeItem(at: t) } }
        let records: [CKRecord] = files.map { f in
            let r = CKRecord(recordType: Self.recordType, recordID: recordID(path: f.path, vaultId: vaultId))
            r["path"] = f.path as NSString
            if f.data.count <= Self.inlineLimit {
                r["data"] = f.data as NSData
            } else {
                let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? f.data.write(to: t)
                tempFiles.append(t)
                r["asset"] = CKAsset(fileURL: t)
            }
            return r
        }
        let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: overwrite ? .allKeys : .ifServerRecordUnchanged, atomically: false)
        for (_, r) in result.saveResults {
            if case .failure(let err) = r {
                if let ck = err as? CKError, ck.code == .serverRecordChanged, !overwrite { continue } // already there
                throw Self.map(err)
            }
        }
    }

    public func delete(paths: [String], vaultId: UUID) async throws {
        let ids = paths.map { recordID(path: $0, vaultId: vaultId) }
        let result = try await db.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
        for (_, r) in result.deleteResults {
            if case .failure(let err) = r {
                if let ck = err as? CKError, ck.code == .unknownItem { continue }
                throw Self.map(err)
            }
        }
    }

    public func fetchChanges(vaultId: UUID, since token: Data?) async throws -> CloudChanges {
        let serverToken: CKServerChangeToken? = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        do {
            let r = try await db.recordZoneChanges(inZoneWith: zoneID(vaultId), since: serverToken)
            var files: [CloudFile] = []
            for (_, res) in r.modificationResultsByID {
                guard case .success(let mod) = res else { continue }
                let rec = mod.record
                guard let path = rec["path"] as? String, Self.isRecordName(rec.recordID.recordName, of: path) else { continue }
                // The server's record of who uploaded it, trusted only if nobody else changed it since.
                let creator = rec.creatorUserRecordID?.recordName
                let author = creator != nil && creator == rec.lastModifiedUserRecordID?.recordName ? creator : nil
                if let d = rec["data"] as? Data {
                    files.append(CloudFile(path: path, data: d, creator: author))
                } else if let a = rec["asset"] as? CKAsset, let u = a.fileURL, let d = try? Data(contentsOf: u) {
                    files.append(CloudFile(path: path, data: d, creator: author))
                }
            }
            let deleted = r.deletions.map { $0.recordID.recordName.replacingOccurrences(of: "|", with: "/") }
            let newToken = try NSKeyedArchiver.archivedData(withRootObject: r.changeToken, requiringSecureCoding: true)
            return CloudChanges(files: files, deletedPaths: deleted, token: newToken, moreComing: r.moreComing)
        } catch let e as CKError {
            switch e.code {
            case .changeTokenExpired: throw CloudTransportError.tokenExpired
            case .zoneNotFound, .userDeletedZone: throw CloudTransportError.zoneMissing
            default: throw Self.map(e)
            }
        }
    }

    public func listVaults() async throws -> [UUID] {
        try await db.allRecordZones().compactMap { z in
            // The shared database mixes every owner's zones; the private one holds only ours.
            if case .shared = scope, z.zoneID.ownerName != ownerName { return nil }
            return Self.vaultId(zoneName: z.zoneID.zoneName)
        }
    }

    public func fetchFile(path: String, vaultId: UUID) async throws -> Data? {
        do {
            let rec = try await db.record(for: recordID(path: path, vaultId: vaultId))
            if let d = rec["data"] as? Data { return d }
            if let a = rec["asset"] as? CKAsset, let u = a.fileURL { return try Data(contentsOf: u) }
            return nil
        } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
            return nil
        }
    }

    static func map(_ error: Error) -> Error {
        guard let ck = error as? CKError else { return error }
        switch ck.code {
        case .notAuthenticated: return CloudTransportError.notSignedIn
        case .permissionFailure: return CloudTransportError.permissionDenied
        case .changeTokenExpired: return CloudTransportError.tokenExpired
        case .zoneNotFound, .userDeletedZone: return CloudTransportError.zoneMissing
        default: return CloudTransportError.other(ck.localizedDescription)
        }
    }
}

extension CloudTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tokenExpired: "iCloud change token expired."
        case .zoneMissing: "The vault no longer exists in iCloud."
        case .notSignedIn: "Not signed in to iCloud on this Mac."
        case .permissionDenied: "This iCloud account may not change that vault."
        case .other(let s): s
        }
    }
}
