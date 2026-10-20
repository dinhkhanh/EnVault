import Testing
import Foundation
@testable import VaultCore

/// Serialized: the app runs one agent server, and the port callback finds it through `AgentServer.current`.
@Suite(.serialized) struct AgentTests {
    @Test func detectsAgentsFromEnvironment() {
        #expect(AIAgents.detect([:]) == nil)
        #expect(AIAgents.detect(["CLAUDECODE": "1"]) == "Claude Code")
        #expect(AIAgents.detect(["CURSOR_AGENT": "1"]) == "Cursor")
        #expect(AIAgents.detect(["ENVAULT_AGENT": "Aider"]) == "Aider")
        #expect(AIAgents.detect(["ENVAULT_AGENT": "1"]) == "AI agent")
        #expect(AIAgents.detect(["ENVAULT_AGENT": "0", "CLAUDECODE": "1"]) == nil)
    }

    @Test func requestDecodesWithoutAgentFields() throws {
        // What a 0.4 CLI sends.
        let r = try JSONDecoder().decode(Agent.Request.self, from: Data(#"{"op":"requestKey","client":"envault get"}"#.utf8))
        #expect(r.agent == nil && r.purpose == nil)
        let resp = try JSONDecoder().decode(Agent.Response.self, from: Data(#"{"ok":false,"error":"x"}"#.utf8))
        #expect(resp.denied == nil)
    }

    @MainActor @Test func keyRequestCarriesAgentAndDenial() async throws {
        let name = "dk.dinhkhanh.envault.agent.test-\(UUID().uuidString.prefix(8))"
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
            try AgentClient(name: name)!.requestKey(vaultId: vaultId, client: "envault run", agent: "Claude\nCode", purpose: .use, detail: "api/.env", timeout: 5)
        }.value
        #expect(key.data == Data(repeating: 7, count: 32))
        #expect(seen.requests.first?.agent == "ClaudeCode")   // sanitized
        #expect(seen.requests.first?.detail == "api/.env")
        #expect(seen.requests.first?.purpose == .use)

        let denial = await Task.detached { () -> Agent.Failure? in
            do { _ = try AgentClient(name: name)!.requestKey(vaultId: vaultId, client: "envault get", agent: "Codex", purpose: .reveal, timeout: 5); return nil }
            catch { return error as? Agent.Failure }
        }.value
        #expect(denial?.denied == true)
        #expect(denial?.message == "no values for agents")

        let info = try await Task.detached { try AgentClient(name: name)!.info() }.value
        #expect(info.agents == AIAgents.Policy())
    }

    @MainActor @Test func vaultThroughTheApp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envault-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = LocalFolderStorage(root: dir)
        let created = try await VaultStore.create(storage: local, passphrase: "pw-123456", kdf: .random(iterations: 1_000))
        _ = try await created.createProject(name: "api")

        let name = "dk.dinhkhanh.envault.agent.test-\(UUID().uuidString.prefix(8))"
        final class Agents: @unchecked Sendable { var seen: [String?] = []; var vaults: [UUID?] = [] }
        let agents = Agents()
        let server = AgentServer(
            info: { Agent.Info(vaultId: nil, vaultPath: dir.path, mode: "icloud", locked: true, appVersion: "test", cliPath: nil) },
            authorize: { _ in throw Agent.Failure("no") },
            storage: { agent, vaultId in
                agents.seen.append(agent)
                agents.vaults.append(vaultId)
                if agent == "Blocked" { throw Agent.Failure("agents off", denied: true) }
                return local
            })
        #expect(server.start(name: name))
        defer { server.stop() }

        let proxy = AppVaultStorage(agent: "Claude Code", portName: name)
        try await Task.detached {
            let store = try await VaultStore.open(storage: proxy)
            _ = try await store.unlock(passphrase: "pw-123456")
            #expect(await store.projects().map(\.name) == ["api"])
            // New revisions are create-only writes: allowed.
            let p = try #require(await store.projects().first)
            _ = try await store.createItem(in: p.id, name: ".env", payload: .envFile(text: "A=1\n"))
        }.value
        let check = try await VaultStore.open(storage: local)
        _ = try await check.unlock(passphrase: "pw-123456")
        #expect(await check.allItems().map(\.name) == [".env"])
        #expect(agents.seen.contains("Claude Code"))
        #expect(agents.vaults.allSatisfy { $0 == nil })   // the open vault

        // A team vault's files are asked for by id.
        let team = UUID()
        _ = try await Task.detached { try await AppVaultStorage(agent: nil, vaultId: team, portName: name).exists(VaultPath("vault.json")) }.value
        #expect(agents.vaults.last == team)

        // Replacing, deleting and leaving the folder are refused.
        await #expect(throws: (any Error).self) { try await proxy.writeReplace(VaultPath("vault.json"), data: Data()) }
        await #expect(throws: (any Error).self) { try await proxy.read(VaultPath("..", "etc", "passwd")) }
        let blocked = AppVaultStorage(agent: "Blocked", portName: name)
        let denial = await Task.detached { () -> Agent.Failure? in
            do { _ = try await blocked.exists(VaultPath("vault.json")); return nil } catch { return error as? Agent.Failure }
        }.value
        #expect(denial?.denied == true)
    }
}
