import Foundation
import VaultCore

/// UserDefaults keys shared by views (`@AppStorage`) and services.
enum Prefs {
    static let autoLockMinutes = "autoLockMinutes"          // default 15, 0 = never
    static let clipboardClearSeconds = "clipboardClearSeconds" // default 30, 0 = never
    static let maskValues = "maskValues"                    // default true
    static let autoMaskSeconds = "autoMaskSeconds"          // default 30, 0 = never; re-hides a temporary reveal
    static let lockOnSleep = "lockOnSleep"                  // default true
    static let biometricUnlock = "biometricUnlock"          // default false until enabled
    static let cliAgentEnabled = "cliAgentEnabled"          // default true: `envault` may ask for the key (Touch ID)
    static let cliInstallPath = "cliInstallPath"            // where Settings linked the CLI, for display
    static let quickCopyHotKey = "quickCopyHotKey"          // HotKeyService.Preset raw value, default optCmdE
    static let quickCopyRecents = "quickCopyRecents"        // ids of recently copied quick-copy hits (no values)
    static let agentsEnabled = "agentsEnabled"              // default true: AI agents may use the vault through envault / MCP
    static let agentValues = "agentValues"                  // AIAgents.Policy.Values: ask (default), never, allow
    static let agentWrites = "agentWrites"                  // default true: agents may change env files
    static let agentApprovalMinutes = "agentApprovalMinutes" // default 5: one approval covers an agent's commands this long; 0 = every command

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
            agentsEnabled: true,
            agentValues: AIAgents.Policy.Values.ask.rawValue,
            agentWrites: true,
            agentApprovalMinutes: 5,
        ])
    }

    static var agentPolicy: AIAgents.Policy {
        let d = UserDefaults.standard
        return AIAgents.Policy(enabled: d.bool(forKey: agentsEnabled),
                               values: AIAgents.Policy.Values(rawValue: d.string(forKey: agentValues) ?? "") ?? .ask,
                               writes: d.bool(forKey: agentWrites),
                               approvalMinutes: d.integer(forKey: agentApprovalMinutes))
    }
}
