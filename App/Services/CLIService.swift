import AppKit
import VaultCore

/// The `envault` command bundled in the app: where it is, linking it into PATH,
/// and the agent that lets it unlock through the app (Touch ID).
@MainActor
enum CLIService {
    /// `EnVault.app/Contents/Helpers/envault` (not Contents/MacOS: on a case-insensitive
    /// disk `envault` would collide with the app's own `EnVault` executable).
    static var bundledCLI: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/envault") }
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: bundledCLI.path) }

    static var installedPath: String? { UserDefaults.standard.string(forKey: Prefs.cliInstallPath) }

    /// `sudo ln -sf …` for people who prefer the terminal, or when the panel can't write there.
    static var terminalInstallCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf \(EnvQuoting.shell(bundledCLI.path)) /usr/local/bin/envault"
    }

    /// Asks where to put the `envault` link (Homebrew's bin by default) and creates
    /// a symlink to the bundled CLI, so app updates update the command too.
    /// Returns an error message, or nil on success/cancel.
    static func installWithPanel() -> String? {
        let panel = NSSavePanel()
        panel.title = "Install the envault Command"
        panel.message = "Choose a folder on your PATH. EnVault puts a link named “envault” there that points into the app, so it stays up to date."
        panel.prompt = "Install"
        panel.nameFieldStringValue = "envault"
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        let home = realHome
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent(".local/bin")]
        panel.directoryURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? home
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            if (try? url.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: bundledCLI)
            UserDefaults.standard.set(url.path, forKey: Prefs.cliInstallPath)
            return nil
        } catch {
            return "Could not create \(url.path): \(error.localizedDescription). Use the Terminal command below instead."
        }
    }

    /// The user's home, not the sandbox container that NSHomeDirectory() returns.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func shellHookLine(_ shell: String) -> String {
        switch shell {
        case "fish": "envault hook fish | source"
        default: "eval \"$(envault hook \(shell))\""
        }
    }

    static func shellRCFile(_ shell: String) -> String {
        switch shell {
        case "fish": "~/.config/fish/config.fish"
        case "bash": "~/.bashrc"
        default: "~/.zshrc"
        }
    }
}

/// Shell quoting for commands the app puts on the clipboard.
enum EnvQuoting {
    static func shell(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./:@+=".unicodeScalars.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
}
