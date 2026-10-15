import Testing
import Foundation
import CryptoKit
@testable import EnvKit

@Suite struct EnvImportTests {
    @Test func flatJSON() throws {
        let text = try EnvImport.dotenv(fromJSON: #"{"DB_URL": "postgres://u:p@h/db", "PORT": 3000, "DEBUG": true, "nested": {"x": 1}}"#)
        let doc = DotEnv.parse(text)
        #expect(doc["DB_URL"] == "postgres://u:p@h/db")
        #expect(doc["PORT"] == "3000")
        #expect(doc["DEBUG"] == "true")
        #expect(doc["nested"] == nil)
    }

    @Test func onePasswordItem() throws {
        let json = #"{"id":"abc","fields":[{"id":"notesPlain","label":"notesPlain","purpose":"NOTES","value":"hi"},{"label":"api key","value":"k1"},{"label":"STRIPE_KEY","value":"k2"},{"label":"empty","value":""}]}"#
        let doc = DotEnv.parse(try EnvImport.dotenv(fromJSON: json))
        #expect(doc.values == ["API_KEY": "k1", "STRIPE_KEY": "k2"])
    }

    @Test func rejectsNonObjects() {
        #expect(throws: EnvImport.ImportError.notAnObject) { try EnvImport.dotenv(fromJSON: "[1,2]") }
        #expect(throws: EnvImport.ImportError.noUsableFields) { try EnvImport.dotenv(fromJSON: "{}") }
    }

    @Test func detectsFormats() {
        #expect(EnvImport.detect(text: "A=1", fileName: ".env") == .dotenv)
        #expect(EnvImport.detect(text: "{\"A\":1}", fileName: "secrets.json") == .json)
        #expect(EnvImport.detect(text: "DOTENV_VAULT_PRODUCTION=\"x\"", fileName: ".env.vault") == .dotenvVault)
        #expect(EnvImport.detect(text: "DOTENV_VAULT_DEVELOPMENT=\"x\"", fileName: "vault.txt") == .dotenvVault)
    }

    @Test func decryptsDotenvVault() throws {
        let keyBytes = Data((0..<32).map { UInt8($0) })
        let hex = keyBytes.map { String(format: "%02x", $0) }.joined()
        let plain = "SECRET=hello\nOTHER=world\n"
        let box = try AES.GCM.seal(Data(plain.utf8), using: SymmetricKey(data: keyBytes))
        let vault = "#/----/\nDOTENV_VAULT_PRODUCTION=\"\(box.combined!.base64EncodedString())\"\n"
        let key = try EnvImport.parseDotenvKey("dotenv://:key_\(hex)@dotenvx.com/vault/.env.vault?environment=production")
        #expect(key.environment == "production")
        #expect(try EnvImport.decryptVault(vault, key: key) == plain)
        #expect(EnvImport.vaultEnvironments(vault) == ["production"])

        let staging = try EnvImport.parseDotenvKey("dotenv://:key_\(hex)@dotenvx.com/vault/.env.vault?environment=staging")
        #expect(throws: EnvImport.ImportError.environmentMissing("staging")) { try EnvImport.decryptVault(vault, key: staging) }
        let wrong = try EnvImport.parseDotenvKey("dotenv://:key_\(String(repeating: "ab", count: 32))@dotenvx.com/vault/.env.vault?environment=production")
        #expect(throws: EnvImport.ImportError.decryptFailed("production")) { try EnvImport.decryptVault(vault, key: wrong) }
        #expect(throws: EnvImport.ImportError.badDotenvKey) { try EnvImport.parseDotenvKey("not a key") }
    }
}

@Suite struct EnvLintTests {
    @Test func findsCommonMistakes() {
        let doc = DotEnv.parse("A=1\nB=\nA=2\nC=changeme\nnot a line\nD=\"open\nE=<your key>\nF=fine\n")
        let issues = EnvLint.check(doc)
        let kinds = issues.map { "\($0.line):\($0.kind.rawValue)" }
        #expect(kinds == ["0:duplicateKey", "1:emptyValue", "3:placeholderValue", "4:invalidLine", "5:unterminatedQuote", "6:placeholderValue"])
        #expect(issues[0].message.contains("line 3"))
    }

    @Test func cleanFileHasNoIssues() {
        #expect(EnvLint.check(DotEnv.parse("# c\nA=1\nB=\"two words\"\n")).isEmpty)
    }
}

@Suite struct EnvDiscoveryTests {
    @Test func groupsByFirstLevelFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evault-disc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ path: String, _ text: String = "A=1\n") throws {
            let u = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try put("shop/.env")
        try put("shop/.env.local")
        try put("shop/.env.example")
        try put("shop/node_modules/x/.env")
        try put("blog/apps/web/.env.production")
        try put("empty/README.md")
        try put(".env")

        let found = EnvDiscovery.discover(in: root)
        #expect(found.map(\.name) == ["blog", "shop", root.lastPathComponent].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(found.first { $0.name == "shop" }?.files.map(\.itemName) == [".env", ".env.local"])
        #expect(found.first { $0.name == "blog" }?.files.map(\.itemName) == ["apps/web/.env.production"])
    }

    @Test func templatesAreNotEnvFiles() {
        #expect(EnvDiscovery.isEnvFile(".env"))
        #expect(EnvDiscovery.isEnvFile(".env.local"))
        #expect(EnvDiscovery.isEnvFile("prod.env"))
        #expect(!EnvDiscovery.isEnvFile(".env.example"))
        #expect(!EnvDiscovery.isEnvFile(".env.sample"))
        #expect(!EnvDiscovery.isEnvFile(".env.vault"))
        #expect(!EnvDiscovery.isEnvFile(".envrc"))
    }
}

@Suite struct GitHookTests {
    @Test func installsIntoEmptyAndExistingHooks() {
        let fresh = GitHook.installing(into: nil)
        #expect(fresh.hasPrefix("#!/bin/sh\n" + GitHook.begin))

        let existing = "#!/bin/bash\nnpm run lint\nexit 0\n"
        let merged = GitHook.installing(into: existing)
        #expect(merged.hasPrefix("#!/bin/bash\n" + GitHook.begin))
        #expect(merged.contains("npm run lint"))
        #expect(GitHook.installing(into: merged) == merged)

        #expect(GitHook.removing(from: merged) == existing)
        #expect(GitHook.removing(from: fresh) == nil)
    }

    @Test func hookFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evault-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try GitHook.install(hooksDir: dir)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        try GitHook.uninstall(hooksDir: dir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func stagedScanFlagsEnvFilesAndHonoursAllow() {
        let token = "ghp_" + String(repeating: "ab12", count: 10)
        let findings = EnvHygiene.scan(staged: [
            (".env", "API=1\n"),
            (".env.example", "API=\n"),
            ("src/a.ts", "const t = \"\(token)\"\n"),
            ("src/b.ts", "const t = \"\(token)\" // evault:allow\n"),
        ])
        #expect(findings.map(\.file) == [".env", "src/a.ts"])
        #expect(findings[0].kind == "Env file committed")
    }
}
