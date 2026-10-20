import Foundation

/// What a window shows and edits: the same for a personal vault
/// (`VaultStore`) and a team vault (`TeamVaultStore`). Requirements spell
/// every argument; the stores' own methods keep their defaults.
public protocol VaultContent: Actor {
    var isUnlocked: Bool { get }
    /// Reads changes other devices made. True when anything changed.
    func refresh() async throws -> Bool
    func lock()

    func projects(includeDeleted: Bool) -> [Project]
    func project(_ id: UUID) -> Project?
    func items(in projectId: UUID) -> [Item]
    func allItems() -> [Item]
    func item(_ id: UUID) -> Item?
    func history(of itemId: UUID) -> [ItemRevision]
    func export(_ projectId: UUID) throws -> (history: [ProjectRevision], items: [[ItemRevision]])

    @discardableResult func createProject(name: String, tags: [String]) async throws -> Project
    @discardableResult func updateProject(_ id: UUID, name: String?, tags: [String]?) async throws -> Project
    func deleteProject(_ id: UUID) async throws
    @discardableResult func createItem(in projectId: UUID, name: String, payload: ItemPayload, tags: [String]) async throws -> Item
    @discardableResult func updateItem(_ id: UUID, name: String?, tags: [String]?, payload: ItemPayload?, projectId: UUID?) async throws -> Item
    func deleteItem(_ id: UUID) async throws
    @discardableResult func restore(_ old: ItemRevision) async throws -> Item
}

extension VaultStore: VaultContent {
    public func refresh() async throws -> Bool { try await refresh(progress: nil) }
}

extension TeamVaultStore: VaultContent {}
