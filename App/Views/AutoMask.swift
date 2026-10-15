import SwiftUI

extension View {
    /// Sets `revealed` back to false after the user's auto-mask delay
    /// (Settings > General). Revealing again restarts the countdown.
    func autoMask(_ revealed: Binding<Bool>) -> some View { modifier(AutoMask(revealed: revealed)) }
}

private struct AutoMask: ViewModifier {
    @AppStorage(Prefs.autoMaskSeconds) private var seconds = 30
    @Binding var revealed: Bool

    func body(content: Content) -> some View {
        content.task(id: "\(revealed)-\(seconds)") {
            guard revealed, seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { revealed = false }
        }
    }
}
