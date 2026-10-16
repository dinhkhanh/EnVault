import Foundation
import CoreServices

/// Watches a folder tree with FSEvents and emits a coalesced signal whenever
/// anything inside changes. iCloud Drive, Dropbox, and git checkouts all land
/// as plain filesystem writes, so this is the only trigger the app needs.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let url: URL
    private let continuation: AsyncStream<Void>.Continuation
    public let changes: AsyncStream<Void>
    private let queue = DispatchQueue(label: "dk.dinhkhanh.envault.folderwatcher")

    public init(url: URL, latency: TimeInterval = 1.0) {
        self.url = url
        var cont: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        start(latency: latency)
    }

    private func start(latency: TimeInterval) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            me.continuation.yield(())
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
