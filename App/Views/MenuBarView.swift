import SwiftUI

/// Menu bar quick-copy: search every key, secret and note. The same list opens
/// in a floating panel from the global shortcut (Settings › General).
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    let openMain: () -> Void
    @AppStorage(Prefs.quickCopyHotKey) private var hotKey = HotKeyService.Preset.optCmdE.rawValue

    var body: some View {
        VStack(spacing: 0) {
            QuickCopyView(style: .menu, openMain: openMain)
                .frame(height: model.phase == .unlocked ? 340 : nil)
            Divider()
            HStack {
                Button("Open EnVault") { openMain() }
                if let preset = HotKeyService.Preset(rawValue: hotKey), preset != .off {
                    Text(preset.title).font(.caption).foregroundStyle(.tertiary).help("Opens quick copy from anywhere")
                }
                Spacer()
                if model.phase == .unlocked { Button("Lock") { model.lock() } }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).padding(8)
        }
        .frame(width: 360)
    }
}
