import SwiftUI
import ToolKit
import EnvKit

struct SecretScanTool: Tool {
    let id = "secret-scan"
    let title = "Secret Scan"
    let subtitle = "Look for API keys, tokens and private keys committed in a project folder. Runs locally; nothing leaves this Mac."
    let systemImage = "magnifyingglass.circle"
    let category = ToolCategory.inspect

    @MainActor func makeView(context: ToolContext) -> AnyView { AnyView(SecretScanView()) }
}

private struct SecretScanView: View {
    @State private var folder: URL?
    @State private var findings: [EnvHygiene.Finding] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var protectResult: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { pick() } label: { Label(folder == nil ? "Choose Folder…" : "Choose Another…", systemImage: "folder") }
                if let f = folder { Text(f.path(percentEncoded: false)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button { protect() } label: { Label("Protect a Repository…", systemImage: "lock.shield") }
                    .help("Install a git pre-commit hook that blocks commits containing secrets or real .env files")
            }
            if let r = protectResult {
                Label(r.text, systemImage: r.ok ? "checkmark.shield" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(r.ok ? .green : .orange)
            }
            if scanned && findings.isEmpty {
                Label("No secrets found.", systemImage: "checkmark.seal").foregroundStyle(.green)
            } else if !findings.isEmpty {
                Text("\(findings.count) finding\(findings.count == 1 ? "" : "s"). Move these into eVault and reference them via environment variables.")
                    .font(.callout).foregroundStyle(.secondary)
                Table(findings) {
                    TableColumn("File") { f in Text("\(f.file):\(f.line)").font(.system(.callout, design: .monospaced)) }
                    TableColumn("Kind", value: \.kind)
                    TableColumn("Excerpt") { f in Text(f.excerpt).font(.system(.callout, design: .monospaced)) }
                }
                .frame(minHeight: 240)
            } else {
                Text("Skips node_modules, .git, build folders and binaries. Patterns: AWS, GitHub, Stripe, Slack, OpenAI, Google keys, private key blocks, JWTs, and generic secret assignments.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// Writes the eVault block into `.git/hooks/pre-commit`. The hook runs the
    /// bundled CLI (`evault scan --staged`), so it works without installing it.
    private func protect() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Protect"
        panel.message = "Choose a git repository. Commits that contain API keys, tokens or real .env files will be stopped."
        guard panel.runModal() == .OK, let repo = panel.url else { return }
        let scoped = repo.startAccessingSecurityScopedResource()
        defer { if scoped { repo.stopAccessingSecurityScopedResource() } }
        let git = repo.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) else {
            protectResult = (false, "\(repo.lastPathComponent) is not a git repository (no .git folder).")
            return
        }
        guard isDir.boolValue else {
            protectResult = (false, "This is a worktree or submodule; run `evault protect` inside it instead.")
            return
        }
        do {
            _ = try GitHook.install(hooksDir: git.appendingPathComponent("hooks"))
            protectResult = (true, "\(repo.lastPathComponent) is protected. Remove with `evault protect --remove`. If the repo sets core.hooksPath, run `evault protect` instead.")
        } catch {
            protectResult = (false, "Could not write the hook: \(error.localizedDescription)")
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a project folder to scan."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        folder = u
        scanning = true; scanned = false
        let scoped = u.startAccessingSecurityScopedResource()
        Task.detached {
            let result = EnvHygiene.scan(folder: u)
            await MainActor.run {
                findings = result
                scanning = false; scanned = true
                if scoped { u.stopAccessingSecurityScopedResource() }
            }
        }
    }
}
