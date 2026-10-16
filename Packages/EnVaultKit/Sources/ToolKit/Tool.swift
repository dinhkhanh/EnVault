import SwiftUI
import VaultCore
import EnvKit

/// Read-only window into the unlocked vault plus small conveniences, handed
/// to every tool. Tools never get the vault key.
public struct ToolContext: Sendable {
    public var projects: @Sendable () async -> [Project]
    public var items: @Sendable (_ projectId: UUID) async -> [Item]
    public var copyToClipboard: @Sendable (_ text: String, _ concealed: Bool) -> Void

    public init(projects: @escaping @Sendable () async -> [Project],
                items: @escaping @Sendable (UUID) async -> [Item],
                copyToClipboard: @escaping @Sendable (String, Bool) -> Void) {
        self.projects = projects
        self.items = items
        self.copyToClipboard = copyToClipboard
    }
}

public enum ToolCategory: String, CaseIterable, Sendable {
    case env = "Env"
    case encoding = "Encoding"
    case generate = "Generate"
    case inspect = "Inspect"
}

/// A tiny developer feature. Add a conformer + one line in the app's
/// `ToolRegistry` and it appears in the sidebar and the menu bar.
public protocol Tool: Sendable {
    var id: String { get }
    var title: String { get }
    var subtitle: String { get }
    var systemImage: String { get }
    var category: ToolCategory { get }
    @MainActor func makeView(context: ToolContext) -> AnyView
}

public struct ToolRegistry: Sendable {
    public let tools: [any Tool]
    public init(_ tools: [any Tool]) { self.tools = tools }

    public func tool(id: String) -> (any Tool)? { tools.first { $0.id == id } }

    public var byCategory: [(ToolCategory, [any Tool])] {
        ToolCategory.allCases.compactMap { c in
            let t = tools.filter { $0.category == c }
            return t.isEmpty ? nil : (c, t)
        }
    }
}
