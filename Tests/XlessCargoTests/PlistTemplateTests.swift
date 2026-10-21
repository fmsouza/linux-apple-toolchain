import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore

@Suite struct PlistTemplateTests {
    @Test func expandsTemplateInNestedValues() throws {
        let out = try PlistTemplate.expand(
            ["A": "@SHORT_VERSION@", "B": ["x-@GIT_SHA@"], "C": ["D": "@VERSION@"], "N": 3],
            vars: ["SHORT_VERSION": "0.10.0", "GIT_SHA": "abc", "VERSION": "0.10.0"])
        #expect(out["A"] as? String == "0.10.0")
        #expect(out["B"] as? [String] == ["x-abc"])
        #expect((out["C"] as? [String: Any])?["D"] as? String == "0.10.0")
        #expect(out["N"] as? Int == 3)
    }

    @Test func unresolvedPlaceholderFails() {
        do {
            _ = try PlistTemplate.expand(["A": "@FOO@", "B": ["@BAR@ @FOO@"], "C": "@OK@"], vars: ["OK": "1"])
            Issue.record("expected an error")
        } catch let e as XlessError {
            #expect(e.stage == .build)
            #expect(e.cause.contains("BAR, FOO"), "cause: \(e.cause)")
        } catch { Issue.record("unexpected error \(error)") }
    }

    @Test func leavesNonTokensAlone() throws {
        let out = try PlistTemplate.expand(["A": "user@example.com", "B": "@lower@", "C": "@@", "D": "@1X@", "E": "@ÄB@", "F": "tail@"], vars: [:])
        #expect(out["A"] as? String == "user@example.com")
        #expect(out["B"] as? String == "@lower@")
        #expect(out["C"] as? String == "@@")
        #expect(out["D"] as? String == "@1X@")
        #expect(out["E"] as? String == "@ÄB@")
        #expect(out["F"] as? String == "tail@")
    }

    @Test func tokenAfterStrayAtSign() throws {
        #expect(try PlistTemplate.expand(["A": "a@@X@b"], vars: ["X": "1"])["A"] as? String == "a@1b")
    }

    @Test func replacementsAreNotScannedAgain() throws {
        let out = try PlistTemplate.expand(["A": "@X@"], vars: ["X": "@Y@", "Y": "no"])
        #expect(out["A"] as? String == "@Y@")
    }

    @Test func hostileNestingAndValuesDoNotCrash() throws {
        var deep: Any = "@X@"
        for _ in 0..<500 { deep = [deep] }
        do {
            _ = try PlistTemplate.expand(["A": deep], vars: ["X": "1"])
            Issue.record("expected an error")
        } catch let e as XlessError { #expect(e.stage == .build) }
        let huge = String(repeating: "@a", count: 200_000) + "@X@"
        let out = try PlistTemplate.expand(["H": huge, "D": Data([1, 2]), "B": true, "Date": Date(timeIntervalSince1970: 0)], vars: ["X": "1"])
        #expect((out["H"] as? String)?.hasSuffix("@a1") == true)
        #expect(out["D"] as? Data == Data([1, 2]))
    }
}
