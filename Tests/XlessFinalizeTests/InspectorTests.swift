import Testing
import Foundation
@testable import XlessFinalize
@testable import XlessCore

@Test func reportsPlistAndBinaries() throws {
    let app = try iosApp()
    let r = try Inspector.report(bundle: app, platform: .ios)
    #expect(r.infoPlist["CFBundleExecutable"] == "X")
    #expect(r.binaries.map(\.path) == ["X"])
    #expect(r.binaries[0].buildVersions == ["platform=2 minos=17.0 sdk=17.0"])
}
