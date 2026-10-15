import Testing
import Foundation
@testable import VaultCore

@Suite struct AgentTests {
    @Test func detectsAgentsFromEnvironment() {
        #expect(AIAgents.detect([:]) == nil)
        #expect(AIAgents.detect(["CLAUDECODE": "1"]) == "Claude Code")
        #expect(AIAgents.detect(["CURSOR_AGENT": "1"]) == "Cursor")
        #expect(AIAgents.detect(["EVAULT_AGENT": "Aider"]) == "Aider")
        #expect(AIAgents.detect(["EVAULT_AGENT": "1"]) == "AI agent")
        #expect(AIAgents.detect(["EVAULT_AGENT": "0", "CLAUDECODE": "1"]) == nil)
    }

    @Test func requestDecodesWithoutAgentFields() throws {
        // What a 0.4 CLI sends.
        let r = try JSONDecoder().decode(Agent.Request.self, from: Data(#"{"op":"requestKey","client":"evault get"}"#.utf8))
        #expect(r.agent == nil && r.purpose == nil)
        let resp = try JSONDecoder().decode(Agent.Response.self, from: Data(#"{"ok":false,"error":"x"}"#.utf8))
        #expect(resp.denied == nil)
    }

    @MainActor @Test func keyRequestCarriesAgentAndDenial() async throws {
        let name = "dk.dinhkhanh.evault.agent.test-\(UUID().uuidString.prefix(8))"
        final class Seen: @unchecked Sendable { var requests: [Agent.KeyRequest] = [] }
        let seen = Seen()
        let server = AgentServer(
            info: { Agent.Info(vaultId: nil, vaultPath: nil, mode: nil, locked: true, appVersion: "test", cliPath: nil, agents: AIAgents.Policy()) },
            authorize: { r in
                seen.requests.append(r)
                if r.purpose == .reveal { throw Agent.Failure("no values for agents", denied: true) }
                return VaultKey(data: Data(repeating: 7, count: 32))
            })
        #expect(server.start(name: name))
        defer { server.stop() }
        let vaultId = UUID()

        let key = try await Task.detached {
            try AgentClient(name: name)!.requestKey(vaultId: vaultId, client: "evault run", agent: "Claude\nCode", purpose: .use, detail: "api/.env", timeout: 5)
        }.value
        #expect(key.data == Data(repeating: 7, count: 32))
        #expect(seen.requests.first?.agent == "ClaudeCode")   // sanitized
        #expect(seen.requests.first?.detail == "api/.env")
        #expect(seen.requests.first?.purpose == .use)

        let denial = await Task.detached { () -> Agent.Failure? in
            do { _ = try AgentClient(name: name)!.requestKey(vaultId: vaultId, client: "evault get", agent: "Codex", purpose: .reveal, timeout: 5); return nil }
            catch { return error as? Agent.Failure }
        }.value
        #expect(denial?.denied == true)
        #expect(denial?.message == "no values for agents")

        let info = try await Task.detached { try AgentClient(name: name)!.info() }.value
        #expect(info.agents == AIAgents.Policy())
    }
}
