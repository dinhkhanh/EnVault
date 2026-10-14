import AppKit

/// Locks the vault after inactivity, on sleep, and when the screen locks.
@MainActor
final class AutoLock {
    private var timer: Timer?
    private var observers: [Any] = []
    private let onLock: @MainActor () -> Void

    init(onLock: @escaping @MainActor () -> Void) {
        self.onLock = onLock
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled() }
        })
    }

    private func lockIfEnabled() {
        if UserDefaults.standard.bool(forKey: Prefs.lockOnSleep) { onLock() }
    }

    /// Call on any user activity to push the inactivity deadline.
    func touch() {
        timer?.invalidate()
        let minutes = UserDefaults.standard.integer(forKey: Prefs.autoLockMinutes)
        guard minutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onLock() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
