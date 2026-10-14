import SwiftUI
import ToolKit

struct ToolHostView: View {
    @Environment(AppModel.self) private var model
    let tool: any Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tool.subtitle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                tool.makeView(context: model.toolContext)
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(tool.title)
    }
}
