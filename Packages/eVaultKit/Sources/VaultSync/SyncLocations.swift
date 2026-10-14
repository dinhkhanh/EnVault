import Foundation

/// Well-known places a vault folder can live.
public enum SyncLocations {
    /// `~/Library/Mobile Documents/com~apple~CloudDocs` if iCloud Drive is enabled.
    public static var iCloudDriveRoot: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static var defaultVaultFolderName: String { "eVault" }

    /// Suggested default: an `eVault` folder in iCloud Drive, falling back to Documents.
    public static var suggestedVaultURL: URL {
        (iCloudDriveRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
            .appendingPathComponent(defaultVaultFolderName, isDirectory: true)
    }

    public static func isInsideICloudDrive(_ url: URL) -> Bool {
        guard let root = iCloudDriveRoot else { return false }
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
    }
}
