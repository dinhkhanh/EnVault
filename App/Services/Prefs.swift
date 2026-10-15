import Foundation

/// UserDefaults keys shared by views (`@AppStorage`) and services.
enum Prefs {
    static let autoLockMinutes = "autoLockMinutes"          // default 15, 0 = never
    static let clipboardClearSeconds = "clipboardClearSeconds" // default 30, 0 = never
    static let maskValues = "maskValues"                    // default true
    static let autoMaskSeconds = "autoMaskSeconds"          // default 30, 0 = never; re-hides a temporary reveal
    static let lockOnSleep = "lockOnSleep"                  // default true
    static let biometricUnlock = "biometricUnlock"          // default false until enabled
    static let cliAgentEnabled = "cliAgentEnabled"          // default true: `evault` may ask for the key (Touch ID)
    static let cliInstallPath = "cliInstallPath"            // where Settings linked the CLI, for display
    static let quickCopyHotKey = "quickCopyHotKey"          // HotKeyService.Preset raw value, default optCmdE
    static let quickCopyRecents = "quickCopyRecents"        // ids of recently copied quick-copy hits (no values)

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoLockMinutes: 15,
            clipboardClearSeconds: 30,
            maskValues: true,
            autoMaskSeconds: 30,
            lockOnSleep: true,
            biometricUnlock: false,
            cliAgentEnabled: true,
            quickCopyHotKey: "optCmdE",
        ])
    }
}
