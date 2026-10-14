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
    }
}
