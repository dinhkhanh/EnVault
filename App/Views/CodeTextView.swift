import SwiftUI
import AppKit

/// Monospaced editor with lightweight dotenv highlighting (keys, values,
/// comments). Plain NSTextView; no third-party dependency.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.usesFindBar = true
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = text
        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        guard tv.string != text else { return }
        let sel = tv.selectedRanges
        tv.string = text
        tv.selectedRanges = sel.filter { ($0 as! NSRange).upperBound <= (text as NSString).length }
        context.coordinator.highlight(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        private static let keyRegex = try! NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*="#, options: [.anchorsMatchLines])
        private static let commentRegex = try! NSRegularExpression(pattern: #"^\s*#.*$"#, options: [.anchorsMatchLines])
        private static let exportRegex = try! NSRegularExpression(pattern: #"^\s*(export)\s+"#, options: [.anchorsMatchLines])

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let s = storage.string as NSString
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), range: full)
            for m in Self.keyRegex.matches(in: s as String, range: full) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: m.range(at: 1))
            }
            for m in Self.exportRegex.matches(in: s as String, range: full) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: m.range(at: 1))
            }
            for m in Self.commentRegex.matches(in: s as String, range: full) {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            }
            storage.endEditing()
        }
    }
}
