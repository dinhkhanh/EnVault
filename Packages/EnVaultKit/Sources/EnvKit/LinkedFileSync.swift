import Foundation
import CryptoKit

/// Two-way sync between a vault item and a file in a project folder. The only
/// state is the hash of what was last written to the file (or read from it):
/// the file differs from it → edited on disk; the vault differs from it →
/// changed in the vault.
public enum LinkedFileSync {
    public enum Action: Equatable, Sendable {
        /// Already the same.
        case none
        /// Changed in the vault (or the file is missing): write the file.
        case writeFile(String)
        /// Edited on disk only: save the file's text as a new vault revision.
        case saveToVault(String)
        /// Edited in both places, on different keys: save to the vault and write the file.
        case merged(String)
        /// Edited in both places on the same keys (empty: no common base to compare with).
        case conflict([String])
        /// Edited on disk, and the link doesn't import edits.
        case editedOnDisk
    }

    public static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `plan` needs the text last written to the file (both sides changed).
    public static func needsBase(disk: String?, vault: String, lastWritten: String?, importEdits: Bool) -> Bool {
        guard importEdits, let disk else { return false }
        let d = hash(disk), v = hash(vault)
        return d != v && d != lastWritten && v != lastWritten
    }

    /// - Parameters:
    ///   - disk: the file's text, nil if it doesn't exist.
    ///   - lastWritten: hash of the text last written to (or imported from) the file.
    ///   - base: that text, when known (for merging edits made in both places).
    public static func plan(disk: String?, vault: String, lastWritten: String?, importEdits: Bool, force: Bool = false, base: String? = nil) -> Action {
        guard let disk else { return .writeFile(vault) }
        let d = hash(disk), v = hash(vault)
        if d == v { return .none }
        if force || d == lastWritten { return .writeFile(vault) }
        guard importEdits else { return .editedOnDisk }
        if v == lastWritten { return .saveToVault(disk) }
        guard let base, hash(base) == lastWritten else { return .conflict([]) }
        let r = EnvMerge.merge(base: base, edited: disk, other: vault)
        if let text = r.text { return text == vault ? .writeFile(vault) : .merged(text) }
        return .conflict(r.conflicts)
    }
}
