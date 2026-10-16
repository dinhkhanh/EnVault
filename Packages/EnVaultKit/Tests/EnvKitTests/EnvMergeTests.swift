import Testing
@testable import EnvKit

@Suite struct EnvMergeTests {
    let base = """
    # app
    A=1
    B=2
    C=3

    """

    @Test func differentKeysCombine() {
        let file = "# app\nA=10\nB=2\nC=3\n# mine\n"
        let vault = "# app\nA=1\nB=20\nC=3\nD=\"new value\" # added\n"
        let r = EnvMerge.merge(base: base, edited: file, other: vault)
        #expect(r.conflicts.isEmpty)
        #expect(r.text == "# app\nA=10\nB=20\nC=3\n# mine\nD=\"new value\" # added\n")
    }

    @Test func removalOnOneSide() {
        let file = "# app\nA=1\nB=2\nC=3\nE=5\n"
        let vault = "# app\nA=1\nC=3\n"
        let r = EnvMerge.merge(base: base, edited: file, other: vault)
        #expect(r.text == "# app\nA=1\nC=3\nE=5\n")
    }

    @Test func sameChangeOnBothSidesIsNoConflict() {
        let file = "# app\nA=9\nB=2\nC=3\n"
        let vault = "A=9\nB=2\nC=3\n"
        let r = EnvMerge.merge(base: base, edited: file, other: vault)
        #expect(r.conflicts.isEmpty)
        #expect(r.text == file)
    }

    @Test func sameKeyChangedDifferentlyConflicts() {
        let file = "# app\nA=file\nB=2\nC=4\n"
        let vault = "# app\nA=vault\nB=2\n"
        let r = EnvMerge.merge(base: base, edited: file, other: vault)
        #expect(r.text == nil)
        #expect(r.conflicts == ["A", "C"]) // C: changed in the file, removed in the vault
    }

    @Test func addedKeysKeepTheirOrder() {
        let r = EnvMerge.merge(base: "A=1\n", edited: "A=1\n", other: "Z=26\nA=1\nM=13\n")
        #expect(r.text == "A=1\nZ=26\nM=13\n")
    }
}

@Suite struct LinkedFileSyncTests {
    let h = LinkedFileSync.hash

    @Test func vaultChangeWritesFile() {
        #expect(LinkedFileSync.plan(disk: "A=1\n", vault: "A=2\n", lastWritten: h("A=1\n"), importEdits: true) == .writeFile("A=2\n"))
        #expect(LinkedFileSync.plan(disk: nil, vault: "A=2\n", lastWritten: h("A=1\n"), importEdits: true) == .writeFile("A=2\n"))
        #expect(LinkedFileSync.plan(disk: "A=2\n", vault: "A=2\n", lastWritten: nil, importEdits: true) == .none)
    }

    @Test func fileEditIsSavedToVault() {
        #expect(LinkedFileSync.plan(disk: "A=9\n", vault: "A=1\n", lastWritten: h("A=1\n"), importEdits: true) == .saveToVault("A=9\n"))
        #expect(!LinkedFileSync.needsBase(disk: "A=9\n", vault: "A=1\n", lastWritten: h("A=1\n"), importEdits: true))
    }

    @Test func importsOffLeavesTheChoiceToTheUser() {
        #expect(LinkedFileSync.plan(disk: "A=9\n", vault: "A=1\n", lastWritten: h("A=1\n"), importEdits: false) == .editedOnDisk)
        #expect(LinkedFileSync.plan(disk: "A=9\n", vault: "A=1\n", lastWritten: h("A=1\n"), importEdits: false, force: true) == .writeFile("A=1\n"))
    }

    @Test func bothChangedMergesByKey() {
        let base = "A=1\nB=2\n"
        let disk = "A=10\nB=2\n", vault = "A=1\nB=20\n"
        #expect(LinkedFileSync.needsBase(disk: disk, vault: vault, lastWritten: h(base), importEdits: true))
        #expect(LinkedFileSync.plan(disk: disk, vault: vault, lastWritten: h(base), importEdits: true, base: base) == .merged("A=10\nB=20\n"))
        #expect(LinkedFileSync.plan(disk: "A=3\nB=2\n", vault: "A=4\nB=2\n", lastWritten: h(base), importEdits: true, base: base) == .conflict(["A"]))
    }

    @Test func noBaseIsAConflict() {
        // A new link onto an existing, different file; or the base revision was compacted away.
        #expect(LinkedFileSync.plan(disk: "A=1\n", vault: "A=2\n", lastWritten: nil, importEdits: true) == .conflict([]))
        #expect(LinkedFileSync.plan(disk: "A=1\n", vault: "A=2\n", lastWritten: h("X"), importEdits: true, base: "other") == .conflict([]))
    }
}
