import SwiftUI
import AppKit

/// Monospaced editor with lightweight dotenv highlighting (keys, values,
/// comments) and line numbers; lines with lint issues get an orange number.
/// Plain NSTextView; no third-party dependency.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    /// Zero-based lines to flag in the gutter.
    var flaggedLines: Set<Int> = []

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

        // Line numbers. Touching layoutManager opts this view into TextKit 1, which the ruler draws with.
        _ = tv.layoutManager
        let ruler = LineNumberRuler(textView: tv)
        ruler.flagged = flaggedLines
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if let ruler = scroll.verticalRulerView as? LineNumberRuler, ruler.flagged != flaggedLines {
            ruler.flagged = flaggedLines
            ruler.needsDisplay = true
        }
        guard tv.string != text else { return }
        let sel = tv.selectedRanges
        tv.string = text
        tv.selectedRanges = sel.filter { ($0 as! NSRange).upperBound <= (text as NSString).length }
        context.coordinator.highlight(tv)
    }

    @MainActor
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

/// Gutter with line numbers for an NSTextView (TextKit 1).
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    var flagged: Set<Int> = []
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }

        let s = tv.string as NSString
        let origin = tv.textContainerOrigin
        func draw(_ number: Int, atY y: CGFloat, height: CGFloat) {
            let color: NSColor = flagged.contains(number - 1) ? .systemOrange : .tertiaryLabelColor
            let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: color])
            let size = label.size()
            let p = convert(NSPoint(x: 0, y: y + origin.y), from: tv)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: p.y + (height - size.height) / 2))
        }

        guard s.length > 0 else { draw(1, atY: 0, height: font.boundingRectForFont.height); return }
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = s.substring(to: chars.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var index = chars.location
        while index <= NSMaxRange(chars), index < s.length {
            let lineRange = s.lineRange(for: NSRange(location: index, length: 0))
            let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lineRange.location), effectiveRange: nil)
            draw(line, atY: frag.minY, height: frag.height)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty line after a trailing newline.
        if s.hasSuffix("\n"), index >= s.length {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 { draw(line, atY: extra.minY, height: extra.height) }
        }
    }
}
