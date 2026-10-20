import Foundation

/// Gated capabilities. Keep this list the single source of truth for what
/// Free vs Pro means; the UI asks `Entitlements.allows(_:)`.
public enum Feature: String, CaseIterable, Sendable {
    case unlimitedProjects      // free: up to `freeProjectLimit`
    case cloudKitSync           // iCloud (CloudKit) mode
    case menuBarQuickCopy
    case developerTools         // the Tools section
    case cliIntegration         // `envault link` / shell hook (the CLI itself stays open)
    case folderSync             // env files kept written into project folders
    case teamSharing            // reserved for the Team plan

    public var title: String {
        switch self {
        case .unlimitedProjects: "Unlimited projects"
        case .cloudKitSync: "iCloud sync (CloudKit)"
        case .menuBarQuickCopy: "Menu bar quick copy"
        case .developerTools: "Developer tools"
        case .cliIntegration: "Shell integration"
        case .folderSync: "Env files kept in sync in project folders"
        case .teamSharing: "Team sharing"
        }
    }

    public var minimumPlan: Plan {
        switch self {
        case .teamSharing: .team
        default: .pro
        }
    }
}

public struct Entitlements: Equatable, Sendable {
    public static let freeProjectLimit = 3

    public var plan: Plan
    public var license: License?

    public init(plan: Plan, license: License? = nil) { self.plan = plan; self.license = license }
    public static let free = Entitlements(plan: .free)

    public func allows(_ feature: Feature) -> Bool {
        rank(plan) >= rank(feature.minimumPlan)
    }

    /// Whether one more project may be created given `count` existing ones.
    public func canAddProject(existing count: Int) -> Bool {
        allows(.unlimitedProjects) || count < Self.freeProjectLimit
    }

    private func rank(_ p: Plan) -> Int {
        switch p { case .free, .teamVault: 0; case .pro: 1; case .team: 2 }
    }
}
