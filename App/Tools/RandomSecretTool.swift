import SwiftUI
import ToolKit
import VaultCore

struct RandomSecretTool: Tool {
    let id = "random-secret"
    let title = "Random Secret"
    let subtitle = "Cryptographically random strings for session secrets, API keys, and salts."
    let systemImage = "dice"
    let category = ToolCategory.generate

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(RandomSecretView(context: context)) }
}

private struct RandomSecretView: View {
    let context: ToolContext
    enum Format: String, CaseIterable { case hex = "Hex", base64 = "Base64", base64url = "Base64 URL", alnum = "Alphanumeric" }
    @State private var bytes = 32
    @State private var format = Format.hex
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Stepper("Bytes: \(bytes)", value: $bytes, in: 8...128, step: 8)
                Picker("Format", selection: $format) { ForEach(Format.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 240)
                Button("Generate", action: generate).keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { context.copyToClipboard(output, true) } label: { Image(systemName: "doc.on.doc") }.disabled(output.isEmpty)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Copied values are concealed from clipboard managers and cleared automatically.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear(perform: generate)
        .onChange(of: bytes) { generate() }
        .onChange(of: format) { generate() }
    }

    private func generate() {
        let d = SecureRandom.bytes(bytes)
        output = switch format {
        case .hex: d.map { String(format: "%02x", $0) }.joined()
        case .base64: d.base64EncodedString()
        case .base64url: d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        case .alnum: {
            let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            return String(d.map { a[Int($0) % a.count] })
        }()
        }
    }
}
