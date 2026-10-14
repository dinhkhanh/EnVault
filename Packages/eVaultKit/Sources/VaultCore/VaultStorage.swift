import Foundation

/// A path relative to the vault root, e.g. `projects/<id>/items/<id>/<ulid>.evr`.
public struct VaultPath: Hashable, Sendable, CustomStringConvertible {
    public var components: [String]
    public init(_ components: [String]) { self.components = components }
    public init(_ components: String...) { self.components = components }
    public var string: String { components.joined(separator: "/") }
    public var description: String { string }
    public func appending(_ c: String) -> VaultPath { VaultPath(components + [c]) }
    public var lastComponent: String { components.last ?? "" }
}

/// Where the vault's files live. Implementations: a local folder (which may be
/// inside iCloud Drive / Dropbox), later CloudKit or git.
///
/// Revision files are create-only and never modified; only `vault.json` is
/// ever replaced (passphrase change) and only revision files are ever deleted
/// (compaction).
public protocol VaultStorage: Sendable {
    func exists(_ path: VaultPath) async throws -> Bool
    func read(_ path: VaultPath) async throws -> Data
    /// Creates a new file. Must fail if the file already exists.
    func writeNew(_ path: VaultPath, data: Data) async throws
    /// Atomically replaces (or creates) a file.
    func writeReplace(_ path: VaultPath, data: Data) async throws
    func delete(_ path: VaultPath) async throws
    /// Names of the entries directly inside `directory`. Empty if it doesn't exist.
    func list(_ directory: VaultPath) async throws -> [String]
}

/// Plain filesystem implementation. Uses `NSFileCoordinator` so it is safe to
/// point at an iCloud Drive folder; evicted files are downloaded on read.
public struct LocalFolderStorage: VaultStorage {
    public let root: URL
    public init(root: URL) { self.root = root }

    func url(_ p: VaultPath) -> URL { p.components.reduce(root) { $0.appendingPathComponent($1) } }

    public func exists(_ path: VaultPath) async throws -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    public func read(_ path: VaultPath) async throws -> Data {
        let u = url(path)
        try ensureDownloaded(u)
        return try coordinated(reading: u) { try Data(contentsOf: $0) }
    }

    public func writeNew(_ path: VaultPath, data: Data) async throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(writing: u, options: .forReplacing) { dst in
            // O_EXCL semantics: fail if it exists.
            guard !FileManager.default.fileExists(atPath: dst.path) else { throw VaultError.io("Refusing to overwrite \(path)") }
            try data.write(to: dst, options: [.atomic])
        }
    }

    public func writeReplace(_ path: VaultPath, data: Data) async throws {
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(writing: u, options: .forReplacing) { try data.write(to: $0, options: [.atomic]) }
    }

    public func delete(_ path: VaultPath) async throws {
        let u = url(path)
        try coordinated(writing: u, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
    }

    public func list(_ directory: VaultPath) async throws -> [String] {
        let u = url(directory)
        guard FileManager.default.fileExists(atPath: u.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: u.path)
        // iCloud Drive represents not-yet-downloaded files as ".name.icloud".
        return names.compactMap { n in
            if n.hasPrefix(".") {
                if n.hasSuffix(".icloud") { return String(n.dropFirst().dropLast(".icloud".count)) }
                return nil
            }
            return n
        }
    }

    // MARK: - helpers

    private func ensureDownloaded(_ u: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: u.path) { return }
        let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
        guard fm.fileExists(atPath: placeholder.path) else { throw VaultError.io("Missing file \(u.lastPathComponent)") }
        try fm.startDownloadingUbiquitousItem(at: u)
        let deadline = Date().addingTimeInterval(30)
        while !fm.fileExists(atPath: u.path) {
            if Date() > deadline { throw VaultError.io("Timed out downloading \(u.lastPathComponent) from iCloud") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func coordinated<T>(reading u: URL, _ body: (URL) throws -> T) throws -> T {
        var coordError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: u, options: [], error: &coordError) { url in
            result = Result { try body(url) }
        }
        if let coordError { throw VaultError.io(coordError.localizedDescription) }
        return try result!.get()
    }

    private func coordinated(writing u: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: u, options: options, error: &coordError) { url in
            result = Result { try body(url) }
        }
        if let coordError { throw VaultError.io(coordError.localizedDescription) }
        try result!.get()
    }
}

/// In-memory storage for tests and previews.
public actor MemoryStorage: VaultStorage {
    private var files: [String: Data] = [:]
    public init() {}
    public func exists(_ path: VaultPath) async throws -> Bool { files[path.string] != nil }
    public func read(_ path: VaultPath) async throws -> Data {
        guard let d = files[path.string] else { throw VaultError.io("Missing \(path)") }
        return d
    }
    public func writeNew(_ path: VaultPath, data: Data) async throws {
        guard files[path.string] == nil else { throw VaultError.io("Refusing to overwrite \(path)") }
        files[path.string] = data
    }
    public func writeReplace(_ path: VaultPath, data: Data) async throws { files[path.string] = data }
    public func delete(_ path: VaultPath) async throws { files[path.string] = nil }
    public func list(_ directory: VaultPath) async throws -> [String] {
        let prefix = directory.string + "/"
        var names = Set<String>()
        for k in files.keys where k.hasPrefix(prefix) {
            let rest = k.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { names.insert(String(rest[..<slash])) } else { names.insert(String(rest)) }
        }
        return Array(names)
    }
    /// Test helper: simulate another device by copying the whole file set.
    public func allFiles() -> [String: Data] { files }
    public func merge(_ other: [String: Data]) { for (k, v) in other where files[k] == nil { files[k] = v } }
}
