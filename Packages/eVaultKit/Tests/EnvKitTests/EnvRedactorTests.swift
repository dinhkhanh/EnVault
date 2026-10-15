import Testing
import Foundation
@testable import EnvKit

@Suite struct EnvRedactorTests {
    static let doc = DotEnv.parse("PORT=3000\nDEBUG=true\nAPI_KEY=s3cr3t-value-123\nSHORT=abc\nDB_PASSWORD=hunter2hunter2\nDB_URL=postgres://u:hunter2hunter2@db/x\n")

    @Test func redactsSecretsKeepsHarmlessValues() {
        let out = EnvRedactor.redact("port 3000 debug true key=s3cr3t-value-123 abc\n", using: Self.doc)
        #expect(out == "port 3000 debug true key=[redacted:API_KEY] abc\n")
    }

    @Test func longestValueWins() {
        let out = EnvRedactor.redact("url postgres://u:hunter2hunter2@db/x pw hunter2hunter2", using: Self.doc)
        #expect(out == "url [redacted:DB_URL] pw [redacted:DB_PASSWORD]")
    }

    @Test func matchesSplitAcrossChunks() {
        let text = Array("a s3cr3t-value-123 b s3cr3t-value-123".utf8)
        for size in 1...7 {
            var r = EnvRedactor(Self.doc)
            var out: [UInt8] = []
            var i = 0
            while i < text.count {
                out += r.feed(text[i..<min(i + size, text.count)])
                i += size
            }
            out += r.finish()
            #expect(String(decoding: out, as: UTF8.self) == "a [redacted:API_KEY] b [redacted:API_KEY]", "chunk size \(size)")
        }
    }

    @Test func completeLinesGoOutAtOnce() {
        var r = EnvRedactor(Self.doc)
        #expect(String(decoding: r.feed(Array("a s3cr3t-value-123\nb".utf8)), as: UTF8.self) == "a [redacted:API_KEY]\n")
        #expect(String(decoding: r.finish(), as: UTF8.self) == "b")
    }

    @Test func partialValueAtEndIsFlushed() {
        var r = EnvRedactor(Self.doc)
        let out = r.feed(Array("tail s3cr3t".utf8)) + r.finish()
        #expect(String(decoding: out, as: UTF8.self) == "tail s3cr3t")
    }

    @Test func nothingToRedactPassesThrough() {
        var r = EnvRedactor(DotEnv.parse("PORT=8080\n"))
        #expect(r.isEmpty)
        #expect(String(decoding: r.feed(Array("x 8080".utf8)) + r.finish(), as: UTF8.self) == "x 8080")
    }
}
