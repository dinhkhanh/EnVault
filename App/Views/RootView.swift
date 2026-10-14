import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noVault:
                WelcomeView()
            case .locked:
                LockView()
            case .unlocked:
                MainView()
            }
        }
        .onContinuousHover { _ in model.userActivity() }
        .sheet(isPresented: Binding(get: { model.pendingRecoveryKey != nil }, set: { if !$0 { model.pendingRecoveryKey = nil } })) {
            if let k = model.pendingRecoveryKey {
                RecoveryKeySheet(recoveryKey: k) { model.pendingRecoveryKey = nil }
            }
        }
        .sheet(isPresented: Binding(get: { model.needsPassphraseReset && model.pendingRecoveryKey == nil }, set: { _ in })) {
            SetPassphraseSheet()
        }
    }
}
