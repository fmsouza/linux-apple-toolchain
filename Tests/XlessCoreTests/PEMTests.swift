import Testing
@testable import XlessCore

@Test func pemNormalizerUndoesCIMangling() {
    let clean = "-----BEGIN PRIVATE KEY-----\nAAAA\nBBBB\n-----END PRIVATE KEY-----"
    #expect(PEM.normalize(clean) == clean)
    #expect(PEM.normalize("  \n" + clean + "\n\n ") == clean)
    #expect(PEM.normalize(clean.replacingOccurrences(of: "\n", with: "\r\n")) == clean)
    #expect(PEM.normalize(clean.replacingOccurrences(of: "\n", with: "\r")) == clean)
    #expect(PEM.normalize(clean.replacingOccurrences(of: "\n", with: "\\n")) == clean)
    #expect(PEM.normalize("\"" + clean.replacingOccurrences(of: "\n", with: "\\n") + "\\n\"\n") != clean)   // quotes are not stripped: not a PEM
}
