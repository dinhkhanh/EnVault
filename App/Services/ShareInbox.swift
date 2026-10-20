import CloudKit

/// Holds a vault share link opened before the model can act on it (EnVault
/// launched by the link, or the vault still locked). The model takes it once
/// the personal vault is unlocked.
@MainActor
final class ShareInbox {
    static let shared = ShareInbox()
    /// Set by the model; called for links that arrive while it is listening.
    var handler: ((CKShare.Metadata) -> Void)?
    private var pending: CKShare.Metadata?

    func receive(_ metadata: CKShare.Metadata) {
        if let handler { handler(metadata) } else { pending = metadata }
    }

    func take() -> CKShare.Metadata? {
        defer { pending = nil }
        return pending
    }

    /// Kept for after the next unlock.
    func hold(_ metadata: CKShare.Metadata) { pending = metadata }
}
