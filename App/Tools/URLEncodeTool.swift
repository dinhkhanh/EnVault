import SwiftUI
import ToolKit

struct URLEncodeTool: Tool {
    let id = "url-encode"
    let title = "URL Encode / Decode"
    let subtitle = "Percent-encode values for query strings and connection URLs, or decode them back."
    let systemImage = "link"
    let category = ToolCategory.encoding

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(URLEncodeView(context: context)) }
}

private struct URLEncodeView: View {
    let context: ToolContext
    @State private var input = ""
    @State private var mode = 0
    @State private var plusAsSpace = false

    /// RFC 3986 unreserved characters; everything else is escaped in a component.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// Unreserved + reserved + "%": escapes spaces and non-ASCII but keeps the URL's structure.
    private static let urlAllowed = unreserved.union(CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%"))

    private var output: String {
        switch mode {
        case 0: return input.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        case 1: return input.addingPercentEncoding(withAllowedCharacters: Self.urlAllowed) ?? ""
        default:
            let s = plusAsSpace ? input.replacingOccurrences(of: "+", with: " ") : input
            return s.removingPercentEncoding ?? "(invalid percent-encoding)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text("Encode component").tag(0); Text("Encode URL").tag(1); Text("Decode").tag(2)
            }
            .pickerStyle(.segmented)
            Text(mode == 0 ? "Escapes everything but letters, digits and -._~ (use for a password inside a DSN or a query value)."
                 : mode == 1 ? "Escapes spaces and non-ASCII characters, keeps :/?&= and existing %XX."
                 : "Turns %XX sequences back into characters.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if mode == 2 { Toggle("Treat + as space (form encoding)", isOn: $plusAsSpace) }
            HStack(alignment: .top) {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { context.copyToClipboard(output, true) } label: { Image(systemName: "doc.on.doc") }.disabled(output.isEmpty)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
    }
}
