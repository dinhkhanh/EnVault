import Foundation

/// AI coding agents (Claude Code, Cursor, Codex…) driving `evault`. The idea:
/// an agent can use secrets (run a command with them, add a key) without
/// reading them. Reading values needs the user's approval in eVault.
///
/// The CLI checks are guardrails for well-meaning agents, not a sandbox: an
/// agent with a shell can do whatever the user's account can.
public enum AIAgents {
    /// What a command needs the vault key for. The app's settings decide per purpose.
    public enum Purpose: String, Codable, Sendable {
        /// Names, metadata, and running commands whose output is redacted.
        case use
        /// Changing env files.
        case write
        /// Values leave eVault where the agent can see them (get, pull, env,
        /// unredacted run, deploy).
        case reveal
    }

    /// Settings › AI Agents, as the app reports it to the CLI.
    public struct Policy: Codable, Sendable, Equatable {
        public enum Values: String, Codable, Sendable, CaseIterable { case ask, never, allow }
        public var enabled: Bool
        public var values: Values
        public var writes: Bool
        /// How long one approval lets an agent use the vault without asking again; 0 = every command.
        public var approvalMinutes: Int

        public init(enabled: Bool = true, values: Values = .ask, writes: Bool = true, approvalMinutes: Int = 5) {
            self.enabled = enabled; self.values = values; self.writes = writes; self.approvalMinutes = approvalMinutes
        }
    }

    /// The agent running this process, from the environment it sets, or nil
    /// for a person. `EVAULT_AGENT=<name>` names one; `EVAULT_AGENT=0` opts out.
    public static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let v = env["EVAULT_AGENT"] {
            switch v.lowercased() {
            case "", "0", "false", "no": return nil
            case "1", "true", "yes": return "AI agent"
            default: return v
            }
        }
        if env["CLAUDECODE"] == "1" { return "Claude Code" }
        if env["CURSOR_AGENT"] != nil { return "Cursor" }
        if env["GEMINI_CLI"] != nil { return "Gemini CLI" }
        if env["CODEX_SANDBOX"] != nil || env["CODEX_SANDBOX_NETWORK_DISABLED"] != nil { return "Codex" }
        return nil
    }

    /// Instructions for an agent: paste into AGENTS.md / CLAUDE.md, or install
    /// as a skill (`evault agent-guide --skill`).
    public static let guide = """
    ## Secrets: eVault

    This machine keeps secrets and env files in eVault, not in the repo. Use the
    `evault` command (or the `evault` MCP server) to work with them. You are not
    meant to see secret values; you can still use them.

    - `evault ls --json`: projects and their env files.
    - `evault keys <project> <item> --json`: variable names in an env file (no values).
    - `evault run <project> <item> -- <cmd> [args]`: run a command with the env
      file's variables set. Secret values in its output are replaced with
      `[redacted:KEY]`. Use this for tests, migrations, dev servers, scripts.
    - `evault set <project> <item> KEY=value`: add or change a variable. Pass
      `KEY=-` to read the value from stdin, or `--generate KEY` to store a new
      random secret without seeing it.
    - `evault unset <project> <item> KEY`: remove a variable.
    - `evault example <project> <item>`: a .env.example (secret values blanked).
    - `evault scan [DIR]`: look for leaked secrets in a source tree.
    - `evault status --json`: is eVault running, which vault, what agents may do.

    Rules:
    - Never write real secret values into files in the repo, commit messages,
      code, logs or chat. Reference variables by name.
    - Don't try to work around redaction (encoding output, printing env to files).
    - `evault get`, `pull`, `env` and `run --no-redact` reveal values. eVault asks
      the user to approve those with Touch ID; only use them when the user asked.
    - If a command exits with code 4, eVault needs the user (unlock or approve);
      tell them. Code 5 means they or their settings said no: don't retry.
    - Item names are env file names in eVault (for example `.env.production`);
      `evault ls` shows them.
    """

    public static let skill = """
    ---
    name: evault
    description: Use secrets and env files stored in eVault (API keys, .env files, tokens) without reading their values. Use when a task needs environment variables or secrets, when running tests, migrations or dev servers that need a .env, or when adding or rotating a secret.
    ---

    """ + guide
}
