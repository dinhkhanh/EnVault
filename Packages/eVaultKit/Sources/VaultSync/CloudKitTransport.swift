import Foundation
import CloudKit
import Security

/// Whether this build carries the iCloud entitlement (signed configurations only).
public enum CloudKitAvailability {
    public static let containerIdentifier = "iCloud." + (Bundle.main.bundleIdentifier ?? "dk.dinhkhanh.evault")

    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        guard let services = value as? [String] else { return false }
        return services.contains("CloudKit")
    }
}

/// `CloudVaultTransport` on the user's private CloudKit database.
///
/// Layout: one custom record zone per vault (`vault-<uuid>`), one record of
/// type `VaultFile` per file. Record name = path with `/` replaced by `|`.
/// Small files live in a `data` field, large ones in an `asset`.
/// Incremental sync uses zone change tokens, so no queries or indexes are
/// needed and the Development schema is created just-in-time.
public struct CloudKitTransport: CloudVaultTransport, @unchecked Sendable {
    public static let recordType = "VaultFile"
    static let inlineLimit = 900_000

    private let container: CKContainer
    private var db: CKDatabase { container.privateCloudDatabase }

    public init(containerIdentifier: String = CloudKitAvailability.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }

    static func zoneID(_ vaultId: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "vault-\(vaultId.uuidString)", ownerName: CKCurrentUserDefaultName)
    }
    static func recordID(path: String, vaultId: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: path.replacingOccurrences(of: "/", with: "|"), zoneID: zoneID(vaultId))
    }

    public func ensureVault(_ vaultId: UUID) async throws {
        let zone = CKRecordZone(zoneID: Self.zoneID(vaultId))
        _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
    }

    public func subscribe(_ vaultId: UUID) async throws {
        let sub = CKDatabaseSubscription(subscriptionID: "evault-\(vaultId.uuidString)")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do { _ = try await db.save(sub) } catch let e as CKError where e.code == .serverRejectedRequest { /* exists */ }
    }

    public func upload(_ files: [CloudFile], vaultId: UUID, overwrite: Bool) async throws {
        var tempFiles: [URL] = []
        defer { for t in tempFiles { try? FileManager.default.removeItem(at: t) } }
        let records: [CKRecord] = files.map { f in
            let r = CKRecord(recordType: Self.recordType, recordID: Self.recordID(path: f.path, vaultId: vaultId))
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
        let ids = paths.map { Self.recordID(path: $0, vaultId: vaultId) }
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
            let r = try await db.recordZoneChanges(inZoneWith: Self.zoneID(vaultId), since: serverToken)
            var files: [CloudFile] = []
            for (_, res) in r.modificationResultsByID {
                guard case .success(let mod) = res else { continue }
                let rec = mod.record
                guard let path = rec["path"] as? String else { continue }
                if let d = rec["data"] as? Data {
                    files.append(CloudFile(path: path, data: d))
                } else if let a = rec["asset"] as? CKAsset, let u = a.fileURL, let d = try? Data(contentsOf: u) {
                    files.append(CloudFile(path: path, data: d))
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
            let n = z.zoneID.zoneName
            return n.hasPrefix("vault-") ? UUID(uuidString: String(n.dropFirst(6))) : nil
        }
    }

    public func fetchFile(path: String, vaultId: UUID) async throws -> Data? {
        do {
            let rec = try await db.record(for: Self.recordID(path: path, vaultId: vaultId))
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
        case .other(let s): s
        }
    }
}
