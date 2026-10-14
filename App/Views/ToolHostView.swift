import SwiftUI
import ToolKit

struct ToolHostView: View {
    @Environment(AppModel.self) private var model
    let tool: any Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.title2.bold())
                Text(tool.subtitle).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            tool.makeView(context: model.toolContext)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(tool.title)
    }
}
