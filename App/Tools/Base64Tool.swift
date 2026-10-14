import SwiftUI
import ToolKit

struct Base64Tool: Tool {
    let id = "base64"
    let title = "Base64 / Hex"
    let subtitle = "Encode and decode text, e.g. for Kubernetes secrets or basic-auth headers."
    let systemImage = "textformat.abc.dottedunderline"
    let category = ToolCategory.encoding

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(Base64View(context: context)) }
}

private struct Base64View: View {
    let context: ToolContext
    @State private var input = ""
    @State private var mode = 0

    private var output: String {
        switch mode {
        case 0: Data(input.utf8).base64EncodedString()
        case 1: Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)).map { String(decoding: $0, as: UTF8.self) } ?? "(invalid base64)"
        case 2: Data(input.utf8).map { String(format: "%02x", $0) }.joined()
        default: {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count % 2 == 0 else { return "(odd length)" }
            var bytes = [UInt8](); var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                guard let b = UInt8(s[i..<j], radix: 16) else { return "(invalid hex)" }
                bytes.append(b); i = j
            }
            return String(decoding: bytes, as: UTF8.self)
        }()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text("Text → Base64").tag(0); Text("Base64 → Text").tag(1); Text("Text → Hex").tag(2); Text("Hex → Text").tag(3)
            }
            .pickerStyle(.segmented)
            TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack(alignment: .top) {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { context.copyToClipboard(output, true) } label: { Image(systemName: "doc.on.doc") }.disabled(output.isEmpty)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
    }
}
