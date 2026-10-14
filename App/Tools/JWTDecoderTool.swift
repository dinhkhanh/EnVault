import SwiftUI
import ToolKit

struct JWTDecoderTool: Tool {
    let id = "jwt"
    let title = "JWT Decoder"
    let subtitle = "Decode a JSON Web Token's header and payload locally. Signatures are not verified."
    let systemImage = "person.badge.key"
    let category = ToolCategory.inspect

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(JWTView()) }
}

private struct JWTView: View {
    @State private var token = ""

    private var parts: (header: String, payload: String, error: String?) {
        let segs = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard segs.count >= 2 else { return ("", "", token.isEmpty ? nil : "A JWT has three dot-separated segments.") }
        func decode(_ s: Substring) -> String {
            var b = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b), let obj = try? JSONSerialization.jsonObject(with: d),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "(not valid base64url JSON)" }
            return String(decoding: pretty, as: UTF8.self)
        }
        return (decode(segs[0]), decode(segs[1]), nil)
    }

    private var expiry: String? {
        let segs = token.split(separator: ".")
        guard segs.count >= 2 else { return nil }
        var b = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let exp = obj["exp"] as? Double else { return nil }
        let date = Date(timeIntervalSince1970: exp)
        return (date < Date() ? "Expired " : "Expires ") + date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $token).font(.system(.body, design: .monospaced)).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if let e = parts.error { Text(e).foregroundStyle(.red).font(.callout) }
            if let x = expiry { Text(x).font(.callout).foregroundStyle(x.hasPrefix("Expired") ? .red : .secondary) }
            HStack(alignment: .top, spacing: 12) {
                section("Header", parts.header)
                section("Payload", parts.payload)
            }
        }
        .padding(16)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView { Text(body).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
