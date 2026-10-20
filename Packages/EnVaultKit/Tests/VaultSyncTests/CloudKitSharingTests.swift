import Testing
import Foundation
import CloudKit
@testable import VaultSync

@Suite struct CloudKitSharingTests {
    @Test func sharedZoneKeepsTheOwner() {
        let id = UUID()
        let zone = CloudKitTransport.zoneID(id, ownerName: "_owner123")
        #expect(zone.zoneName == "vault-\(id.uuidString)")
        #expect(zone.ownerName == "_owner123")
        #expect(CloudKitTransport.zoneID(id).ownerName == CKCurrentUserDefaultName)
    }

    @Test func vaultIdFromZoneName() {
        let id = UUID()
        #expect(CloudKitTransport.vaultId(zoneName: CloudKitTransport.zoneName(id)) == id)
        #expect(CloudKitTransport.vaultId(zoneName: "com.apple.coredata.cloudkit.zone") == nil)
        #expect(CloudKitTransport.vaultId(zoneName: "vault-not-a-uuid") == nil)
    }

    @Test func aRecordStandsOnlyForThePathItsNameMapsTo() {
        let path = "identities/\(UUID().uuidString)/01JABC.json"
        #expect(CloudKitTransport.isRecordName(CloudKitTransport.recordName(path), of: path))
        // A copy saved under a name spelled with "/" claims the same path: refused.
        #expect(!CloudKitTransport.isRecordName(path, of: path))
        #expect(!CloudKitTransport.isRecordName("identities|other.json", of: path))
        #expect(!CloudKitTransport.isRecordName("a|b", of: "a|b"))
    }

    @Test func permissionFailureMapsToPermissionDenied() {
        let e = CKError(.permissionFailure)
        #expect(CloudKitTransport.map(e) as? CloudTransportError == .permissionDenied)
    }
}
