import AppKit

/// Copies secrets so that clipboard managers skip them, and clears them again
/// after a timeout unless the user has copied something else since.
@MainActor
final class ClipboardService {
    static let shared = ClipboardService()

    private var clearTask: Task<Void, Never>?

    /// Seconds before an auto-clear. 0 disables.
    var clearAfter: TimeInterval {
        let v = UserDefaults.standard.double(forKey: Prefs.clipboardClearSeconds)
        return UserDefaults.standard.object(forKey: Prefs.clipboardClearSeconds) == nil ? 30 : v
    }

    func copy(_ text: String, concealed: Bool = true) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.string]
        if concealed {
            types.append(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            types.append(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        pb.declareTypes(types, owner: nil)
        pb.setString(text, forType: .string)
        if concealed { for t in types.dropFirst() { pb.setString("", forType: t) } }
        let change = pb.changeCount

        clearTask?.cancel()
        guard concealed, clearAfter > 0 else { return }
        clearTask = Task { [clearAfter] in
            try? await Task.sleep(for: .seconds(clearAfter))
            guard !Task.isCancelled, NSPasteboard.general.changeCount == change else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
