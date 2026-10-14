import SwiftUI
import ToolKit
import VaultCore

struct UUIDTool: Tool {
    let id = "uuid"
    let title = "UUID / ULID"
    let subtitle = "Generate identifiers."
    let systemImage = "number"
    let category = ToolCategory.generate

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(UUIDView(context: context)) }
}

private struct UUIDView: View {
    let context: ToolContext
    @State private var uuid = UUID().uuidString
    @State private var ulid = ULID().string
    @State private var lowercase = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Lowercase UUID", isOn: $lowercase)
            row("UUID v4", lowercase ? uuid.lowercased() : uuid)
            row("ULID", ulid)
            Button("Regenerate") { uuid = UUID().uuidString; ulid = ULID().string }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button { context.copyToClipboard(value, false) } label: { Image(systemName: "doc.on.doc") }
        }
    }
}
