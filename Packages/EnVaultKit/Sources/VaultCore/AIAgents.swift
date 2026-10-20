import Foundation

/// AI coding agents (Claude Code, Cursor, Codex…) driving `envault`. The idea:
/// an agent can use secrets (run a command with them, add a key) without
/// reading them. Reading values needs the user's approval in EnVault.
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
        /// Values leave EnVault where the agent can see them (get, pull, env,
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

        /// This policy, no looser than a team's rules (FR-23): a member's own
        /// setting can only be stricter.
        public func restricted(by team: TeamAgentRules?) -> Policy {
            guard let team else { return self }
            var p = self
            p.enabled = enabled && team.enabled
            p.writes = writes && team.writes
            p.values = [values, team.values].max { $0.strictness < $1.strictness }!
            return p
        }
    }

    /// The agent running this process, from the environment it sets, or nil
    /// for a person. `ENVAULT_AGENT=<name>` names one; `ENVAULT_AGENT=0` opts out, but only
    /// where no agent's own marker is set: an agent could set it itself.
    public static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let v = env["ENVAULT_AGENT"] {
            switch v.lowercased() {
            // An agent could set this itself: it only counts where no agent's own marker is set.
            case "", "0", "false", "no": return marker(env)
            case "1", "true", "yes": return "AI agent"
            default: return v
            }
        }
        return marker(env)
    }

    /// The variables AI agents set in their own shells.
    static func marker(_ env: [String: String]) -> String? {
        if env["CLAUDECODE"] == "1" { return "Claude Code" }
        if env["CURSOR_AGENT"] != nil { return "Cursor" }
        if env["GEMINI_CLI"] != nil { return "Gemini CLI" }
        if env["CODEX_SANDBOX"] != nil || env["CODEX_SANDBOX_NETWORK_DISABLED"] != nil { return "Codex" }
        return nil
    }

    /// Instructions for an agent: paste into AGENTS.md / CLAUDE.md, or install
    /// as a skill (`envault agent-guide --skill`).
    public static let guide = """
    ## Secrets: EnVault

    This machine keeps secrets and env files in EnVault, not in the repo. Use the
    `envault` command (or the `envault` MCP server) to work with them. You are not
    meant to see secret values; you can still use them.

    - `envault ls --json`: projects and their env files.
    - `envault keys <project> <item> --json`: variable names in an env file (no values).
    - `envault run <project> <item> -- <cmd> [args]`: run a command with the env
      file's variables set. Secret values in its output are replaced with
      `[redacted:KEY]`. Use this for tests, migrations, dev servers, scripts.
    - `envault set <project> <item> KEY=value`: add or change a variable. Pass
      `KEY=-` to read the value from stdin, or `--generate KEY` to store a new
      random secret without seeing it.
    - `envault unset <project> <item> KEY`: remove a variable.
    - `envault example <project> <item>`: a .env.example (secret values blanked).
    - `envault scan [DIR]`: look for leaked secrets in a source tree.
    - `envault status --json`: is EnVault running, which vault, what agents may do.
    - Team vaults: `envault teams --json` lists them; add `--team NAME` to any
      command above (MCP tools take a `team` argument). A team's rules may be
      stricter than the user's, and items marked for people only are hidden.

    Rules:
    - Never write real secret values into files in the repo, commit messages,
      code, logs or chat. Reference variables by name.
    - Don't try to work around redaction (encoding output, printing env to files).
    - `envault get`, `pull`, `env` and `run --no-redact` reveal values. EnVault asks
      the user to approve those with Touch ID; only use them when the user asked.
    - If a command exits with code 4, EnVault needs the user (unlock or approve);
      tell them. Code 5 means they or their settings said no: don't retry.
    - Item names are env file names in EnVault (for example `.env.production`);
      `envault ls` shows them.
    """

    public static let skill = """
    ---
    name: envault
    description: Use secrets and env files stored in EnVault (API keys, .env files, tokens) without reading their values. Use when a task needs environment variables or secrets, when running tests, migrations or dev servers that need a .env, or when adding or rotating a secret.
    ---

    """ + guide
}

extension AIAgents.Policy.Values {
    /// never > ask > allow.
    var strictness: Int { switch self { case .allow: 0; case .ask: 1; case .never: 2 } }
}

/// What a team vault's owner or admins allow AI agents (FR-23). Plain data in
/// a signed membership event; every member's own setting can only be stricter.
public struct TeamAgentRules: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var values: AIAgents.Policy.Values
    public var writes: Bool
    public init(enabled: Bool = true, values: AIAgents.Policy.Values = .ask, writes: Bool = true) {
        self.enabled = enabled; self.values = values; self.writes = writes
    }
}
