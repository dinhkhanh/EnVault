import Foundation

/// Finds env files under a workspace folder (say `~/Projects`) and groups them
/// into projects: each first-level subfolder is a project. Files directly in
/// the chosen folder belong to a project named after that folder.
public enum EnvDiscovery {
    public struct FoundFile: Hashable, Sendable, Identifiable {
        public var id: URL { url }
        public var url: URL
        /// Path inside the project folder, used as the item name (".env.local", "apps/web/.env").
        public var itemName: String
    }

    public struct FoundProject: Hashable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var folder: URL
        public var files: [FoundFile]
    }

    static let skipDirs: Set<String> = ["node_modules", ".git", "vendor", "Pods", "build", "dist", ".next", ".nuxt", "target", "DerivedData", ".build", ".venv", "venv", "__pycache__", ".terraform", "coverage", ".cache"]

    /// `.env`, `.env.local`, `production.env`… but not committed templates.
    public static func isEnvFile(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasPrefix(".env") || n.hasSuffix(".env") else { return false }
        return !isTemplate(n) && !n.hasSuffix(".vault") && !n.hasSuffix(".keys") && n != ".envrc"
    }

    public static func isTemplate(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["example", "sample", "template", "dist", "defaults"].contains { n.hasSuffix("." + $0) || n.hasSuffix("-" + $0) || n.hasSuffix("_" + $0) }
    }

    public static func discover(in root: URL, maxDepth: Int = 4) -> [FoundProject] {
        let root = root.standardizedFileURL
        var groups: [String: (folder: URL, files: [FoundFile])] = [:]

        func walk(_ dir: URL, depth: Int, project: (name: String, folder: URL)?) {
            guard depth <= maxDepth, let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
            for u in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { continue }
                if v?.isDirectory == true {
                    guard !skipDirs.contains(u.lastPathComponent), !u.lastPathComponent.hasSuffix(".app") else { continue }
                    walk(u, depth: depth + 1, project: project ?? (u.lastPathComponent, u))
                } else if isEnvFile(u.lastPathComponent) {
                    let p = project ?? (root.lastPathComponent, root)
                    let rel = String(u.standardizedFileURL.path.dropFirst(p.folder.standardizedFileURL.path.count + 1))
                    groups[p.name, default: (p.folder, [])].files.append(FoundFile(url: u, itemName: rel))
                }
            }
        }
        walk(root, depth: 0, project: nil)
        return groups.map { FoundProject(name: $0.key, folder: $0.value.folder, files: $0.value.files) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
