import Testing
import Foundation
@testable import XlessCore

@Test func versionMatchesVersionsEnv() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let env = try String(contentsOf: root.appendingPathComponent("versions.env"), encoding: .utf8)
    #expect(env.contains("XLESS_VERSION=\(XlessVersion.current)\n"))
}
