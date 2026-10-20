import Testing
import Foundation
@testable import EnvKit

@Suite struct EnvHygieneTests {
    @Test func exampleKeepsShapeBlanksSecrets() {
        let doc = DotEnv.parse("# db\nDB_HOST=localhost\nDB_PORT=5432\nDB_PASSWORD=\"hunter2 pass\"\nDEBUG=true\nAPI_KEY=sk_live_abc\n")
        let ex = EnvHygiene.example(from: doc)
        #expect(ex == "# db\nDB_HOST=localhost\nDB_PORT=5432\nDB_PASSWORD=\nDEBUG=true\nAPI_KEY=\n")
        #expect(EnvHygiene.example(from: doc, placeholders: false).contains("DB_PORT=\n"))
    }

    @Test func keyAges() {
        let d0 = Date(timeIntervalSince1970: 0), d1 = Date(timeIntervalSince1970: 100), d2 = Date(timeIntervalSince1970: 200)
        let revs: [(date: Date, text: String)] = [
            (d2, "A=1\nB=new\nC=3"),
            (d1, "A=1\nB=old"),
            (d0, "A=1"),
        ]
        let ages = EnvHygiene.keyAges(revisions: revs)
        #expect(ages["A"] == d0)   // unchanged since the first revision
        #expect(ages["B"] == d2)   // changed in the newest
        #expect(ages["C"] == d2)   // introduced in the newest
        #expect(EnvHygiene.keyAges(revisions: []).isEmpty)
    }

    @Test func exposedKeysFollowTheValueBack() {
        let bob = UUID(), cyd = UUID()
        let revs: [(text: String, readers: Set<UUID>)] = [
            ("A=1\nB=new\nC=3\nD=", []),           // saved after both left
            ("A=1\nB=old\nD=", [cyd]),              // Cyd could read this one
            ("A=1", [bob, cyd]),
        ]
        let exposed = EnvHygiene.exposedKeys(revisions: revs)
        #expect(exposed["A"] == [bob, cyd])   // unchanged since both could read it
        #expect(exposed["B"] == nil)          // changed since
        #expect(exposed["C"] == nil)          // new
        #expect(exposed["D"] == nil)          // empty values aren't secrets
        #expect(EnvHygiene.exposedKeys(revisions: []).isEmpty)
    }

    // Fixtures are assembled at runtime so no token-shaped literal lives in
    // the source (GitHub push protection would otherwise block the repo).
    static let fakeAWS = "AKIA" + "IOSFODNN7" + "EXAMPLE"
    static let fakeGitHub = "ghp_" + String(repeating: "ab12", count: 10)
    static let fakeStripe = "sk_" + "live_" + String(repeating: "x9", count: 12)

    @Test func scannerFindsCommonTokens() {
        let text = """
        aws = "\(Self.fakeAWS)"
        token = "\(Self.fakeGitHub)"
        stripe: \(Self.fakeStripe)
        password = "correct-horse-battery-staple"
        safe = "short"
        placeholder = "xxxx"
        """
        let f = EnvHygiene.scan(text: text, file: "config.rb")
        #expect(f.map(\.kind).sorted() == ["AWS access key", "GitHub token", "Secret assignment", "Stripe key"].sorted())
        #expect(f.allSatisfy { !$0.excerpt.contains(Self.fakeGitHub) })
        #expect(f.first { $0.kind == "GitHub token" }?.line == 2)
    }

    @Test func scanFolderSkipsDependencies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envault-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "KEY=\(Self.fakeAWS)\n".write(to: dir.appendingPathComponent("config.env"), atomically: true, encoding: .utf8)
        try "KEY=\(Self.fakeAWS)\n".write(to: dir.appendingPathComponent("node_modules/x/leak.js"), atomically: true, encoding: .utf8)
        let f = EnvHygiene.scan(folder: dir)
        #expect(f.map(\.file) == ["config.env"])
    }
}
