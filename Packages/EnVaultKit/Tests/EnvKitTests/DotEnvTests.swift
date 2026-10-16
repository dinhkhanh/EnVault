import Testing
import Foundation
@testable import EnvKit

@Suite struct DotEnvParserTests {
    let sample = """
    # Database
    DB_HOST=localhost
    DB_PORT=5432 # default postgres
    export API_KEY="sk-live-abc\\"def"
    SINGLE='it''s raw \\n'
    EMPTY=
    MULTI="line1\\nline2"
    URL=https://example.com/path?x=1#frag
    SPACED = value with spaces
    bad line
    1BAD=x

    LAST=one
    LAST=two
    """

    @Test func parsesEntries() {
        let doc = DotEnv.parse(sample)
        let v = doc.values
        #expect(v["DB_HOST"] == "localhost")
        #expect(v["DB_PORT"] == "5432")
        #expect(v["API_KEY"] == "sk-live-abc\"def")
        #expect(v["SINGLE"] == "it")           // unquoted tail after closing quote is ignored
        #expect(v["EMPTY"] == "")
        #expect(v["MULTI"] == "line1\nline2")
        #expect(v["URL"] == "https://example.com/path?x=1#frag") // '#' without preceding space is not a comment
        #expect(v["SPACED"] == "value with spaces")
        #expect(v["LAST"] == "two")
    }

    @Test func classifiesLines() {
        let doc = DotEnv.parse(sample)
        #expect(doc.lines[0].kind == .comment("Database"))
        #expect(doc.lines[2].entry?.inlineComment == "default postgres")
        #expect(doc.lines[3].entry?.exported == true)
        #expect(doc.lines[3].entry?.quote == .double)
        if case .invalid = doc.lines[9].kind {} else { Issue.record("expected invalid for 'bad line'") }
        if case .invalid = doc.lines[10].kind {} else { Issue.record("expected invalid key '1BAD'") }
        #expect(doc.lines[11].kind == .blank)
    }

    @Test func roundTripsUnchanged() {
        let doc = DotEnv.parse(sample)
        #expect(doc.text == sample)
        let withNewline = sample + "\n"
        #expect(DotEnv.parse(withNewline).text == withNewline)
        #expect(DotEnv.parse("").text == "")
        #expect(DotEnv.parse("A=1\r\nB=2\r\n").values == ["A": "1", "B": "2"])
    }

    @Test func settingEditsInPlaceAndAppends() {
        let doc = DotEnv.parse("A=1\nB=2\n")
        let d2 = doc.setting("A", to: "changed").setting("C", to: "with space")
        #expect(d2.text == "A=changed\nB=2\nC=\"with space\"\n")
        #expect(d2.removing("B").text == "A=changed\nC=\"with space\"\n")
    }

    @Test func serializeEscapes() {
        let e = EnvEntry(key: "K", value: "a\"b\nc", quote: .double)
        #expect(DotEnv.serialize(e) == "K=\"a\\\"b\\nc\"")
        #expect(DotEnv.parse(DotEnv.serialize(e)).values["K"] == "a\"b\nc")
        let plain = EnvEntry(key: "K", value: "simple")
        #expect(DotEnv.serialize(plain) == "K=simple")
    }
}

@Suite struct EnvDiffTests {
    @Test func diffs() {
        let a = DotEnv.parse("A=1\nB=2\nC=3\n")
        let b = DotEnv.parse("A=1\nB=changed\nD=4\n")
        let d = EnvDiff.diff(a, b)
        #expect(d == [.changed(key: "B", old: "2", new: "changed"), .removed(key: "C", value: "3"), .added(key: "D", value: "4")])
        #expect(EnvDiff.missingKeys(in: a, comparedTo: b) == ["D"])
    }
}

@Suite struct EnvExportTests {
    @Test func shellQuoting() {
        let doc = DotEnv.parse("A=it's\nB=plain\n")
        #expect(EnvExport.shell(doc) == "export A='it'\\''s'\nexport B='plain'\n")
        #expect(EnvExport.inlineCommand(doc) == "A='it'\\''s' B='plain'")
        #expect(EnvExport.json(doc).contains("\"B\" : \"plain\""))
        #expect(EnvExport.yaml(doc) == "A: \"it's\"\nB: \"plain\"\n")
    }
}
