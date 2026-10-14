import Testing
@testable import XlessASC

@Test(arguments: [
    ("ITMS-90725: SDK version issue", "SDK version"),
    ("ERROR ITMS-90189: Redundant Binary Upload", "build number"),
    ("The bundle version must be higher than the previously uploaded version", "build number"),
    ("ITMS-90717: Invalid App Store Icon", "alpha"),
    ("ITMS-90135: The executable could not be re-signed", "timestamp"),
    ("ITMS-90062: This bundle is invalid. The value for key CFBundleVersion [1] must contain a higher version", "build number"),
    ("ITMS-90022: Missing required icon file", "parity-known-gaps.md"),
    ("ITMS-90023: Missing required icon file", "parity-known-gaps.md"),
    ("ITMS-90713: Missing Info.plist value CFBundleIconName", "parity-known-gaps.md"),
    ("ITMS-90704: Missing app icon", "parity-known-gaps.md"),
])
func explainsKnownIssues(message: String, fragment: String) {
    #expect(KnownIssues.explain(message)?.contains(fragment) == true)
}

@Test func unknownReturnsNil() { #expect(KnownIssues.explain("something new") == nil) }

@Test func buildNumberHintSaysItMustIncrease() {
    #expect(KnownIssues.explain("ITMS-90062")?.contains("higher") == true)
}

@Test func iconCodesAreAnIconProblem() {
    #expect(KnownIssues.explain("ERROR ITMS-90704") == "app icon problem — see docs/research/parity-known-gaps.md")
}
