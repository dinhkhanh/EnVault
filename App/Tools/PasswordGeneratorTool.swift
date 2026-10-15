import SwiftUI
import ToolKit
import VaultCore

struct PasswordGeneratorTool: Tool {
    let id = "password"
    let title = "Password Generator"
    let subtitle = "Random passwords for database users, admin accounts, and service logins."
    let systemImage = "key"
    let category = ToolCategory.generate

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(PasswordGeneratorView(context: context)) }
}

private struct PasswordGeneratorView: View {
    let context: ToolContext
    @State private var length = 20
    @State private var upper = true
    @State private var lower = true
    @State private var digits = true
    @State private var symbols = true
    @State private var avoidAmbiguous = false
    @State private var output = ""

    /// No quotes, backslash, backtick or $, so values paste safely into .env files and shells.
    private static let symbolSet = "!#%&*+,-./:;<=>?@^_~()[]{}|"
    private static let ambiguous = Set("Il1O0o")

    private var classes: [[Character]] {
        [(upper, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"), (lower, "abcdefghijklmnopqrstuvwxyz"), (digits, "0123456789"), (symbols, Self.symbolSet)]
            .filter(\.0)
            .map { Array($0.1).filter { !avoidAmbiguous || !Self.ambiguous.contains($0) } }
    }

    private var entropyBits: Int {
        let n = classes.reduce(0) { $0 + $1.count }
        return n < 2 ? 0 : Int(Double(length) * log2(Double(n)))
    }

    private var strength: (String, Color) {
        switch entropyBits {
        case ..<60: ("Weak", .red)
        case ..<80: ("Fair", .orange)
        case ..<128: ("Strong", .green)
        default: ("Very strong", .green)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Stepper("Length: \(length)", value: $length, in: 8...128)
                Slider(value: Binding(get: { Double(length) }, set: { length = Int($0) }), in: 8...64, step: 1).frame(width: 200)
                Spacer()
                Button("Generate", action: generate).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Toggle("A–Z", isOn: $upper)
                Toggle("a–z", isOn: $lower)
                Toggle("0–9", isOn: $digits)
                Toggle("Symbols", isOn: $symbols)
                Toggle("Avoid look-alikes (Il1O0o)", isOn: $avoidAmbiguous)
            }
            .toggleStyle(.checkbox)
            HStack {
                Text(output).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { context.copyToClipboard(output, true) } label: { Image(systemName: "doc.on.doc") }.disabled(output.isEmpty)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if classes.isEmpty {
                Text("Pick at least one character set.").font(.caption).foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Text(strength.0).foregroundStyle(strength.1)
                    Text("· about \(entropyBits) bits of entropy").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Text("Symbols skip quotes, backslash, backtick and $ so values paste safely into .env files. Copied values are concealed from clipboard managers and cleared automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear(perform: generate)
        .onChange(of: length) { generate() }
        .onChange(of: [upper, lower, digits, symbols, avoidAmbiguous]) { generate() }
    }

    /// Uniform picks from the combined alphabet; redraws until every chosen set appears.
    private func generate() {
        let sets = classes
        let alphabet = sets.flatMap { $0 }
        guard !alphabet.isEmpty else { output = ""; return }
        var candidate: [Character]
        repeat {
            candidate = (0..<length).map { _ in alphabet[Self.uniformIndex(below: alphabet.count)] }
        } while length >= sets.count && !sets.allSatisfy { set in candidate.contains(where: set.contains) }
        output = String(candidate)
    }

    /// Rejection sampling over random bytes, so no character is more likely than another.
    private static func uniformIndex(below n: Int) -> Int {
        let limit = 256 - 256 % n
        while true {
            let b = Int(SecureRandom.bytes(1)[0])
            if b < limit { return b % n }
        }
    }
}
