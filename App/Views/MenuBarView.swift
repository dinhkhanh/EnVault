import SwiftUI
import VaultCore
import EnvKit

/// Menu bar quick-copy: search every key in every env file and every secret.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    let openMain: () -> Void
    @State private var query = ""
    @State private var copiedId: String?

    struct Hit: Identifiable {
        let id: String
        let project: String
        let item: String
        let key: String
        let value: String
    }

    private var hits: [Hit] {
        guard model.phase == .unlocked else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Hit] = []
        for item in model.items {
            let project = model.projects.first { $0.id == item.projectId }?.name ?? ""
            switch item.payload {
            case .envFile(let text):
                for e in DotEnv.parse(text).entries {
                    out.append(Hit(id: "\(item.id)/\(e.key)", project: project, item: item.name, key: e.key, value: e.value))
                }
            case .secret(let v, _):
                out.append(Hit(id: "\(item.id)", project: project, item: item.name, key: item.name, value: v))
            default: break
            }
        }
        if q.isEmpty { return Array(out.prefix(30)) }
        return out.filter { "\($0.project) \($0.item) \($0.key)".localizedCaseInsensitiveContains(q) }.prefix(50).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.phase == .unlocked {
                TextField("Search keys…", text: $query).textFieldStyle(.roundedBorder).padding(8)
                Divider()
                List(hits) { h in
                    Button {
                        ClipboardService.shared.copy(h.value)
                        copiedId = h.id
                        Task { try? await Task.sleep(for: .seconds(1)); copiedId = nil }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(h.key).font(.system(.body, design: .monospaced))
                                Text("\(h.project) › \(h.item)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: copiedId == h.id ? "checkmark" : "doc.on.doc").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(height: 300)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.title)
                    Text(model.phase == .noVault ? "No vault open" : "Vault is locked").foregroundStyle(.secondary)
                    Button("Open eVault") { openMain() }.buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Open eVault") { openMain() }
                Spacer()
                if model.phase == .unlocked { Button("Lock") { model.lock() } }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).padding(8)
        }
        .frame(width: 340)
    }
}
