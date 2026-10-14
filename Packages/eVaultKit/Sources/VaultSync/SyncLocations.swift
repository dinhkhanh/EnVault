import Foundation

/// Well-known places a vault folder can live.
public enum SyncLocations {
    /// The user's real home, even inside an App Sandbox container.
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` if iCloud Drive is enabled.
    public static var iCloudDriveRoot: URL? {
        let u = realHomeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public static var defaultVaultFolderName: String { "eVault" }

    /// Suggested default: an `eVault` folder in iCloud Drive, falling back to Documents.
    public static var suggestedVaultURL: URL {
        (iCloudDriveRoot ?? realHomeDirectory.appendingPathComponent("Documents"))
            .appendingPathComponent(defaultVaultFolderName, isDirectory: true)
    }

    public static func isInsideICloudDrive(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }
}
