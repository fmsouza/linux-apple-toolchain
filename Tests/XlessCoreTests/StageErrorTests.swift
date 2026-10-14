import Testing
import Foundation
@testable import XlessCore

@Test func withStagePassesXlessErrorThrough() async {
    do { _ = try await withStage(.sign) { throw XlessError(.config, "bad", fix: "fix it") }; Issue.record("expected throw") }
    catch let e as XlessError { #expect(e == XlessError(.config, "bad", fix: "fix it")) }
    catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageMapsCocoaErrorToStage() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())/out")
    do {
        _ = try await withStage(.upload) { try FileManager.default.contentsOfDirectory(at: missing, includingPropertiesForKeys: nil) }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .upload)
        #expect(e.stage.exitCode == 17)
        #expect(e.description.hasPrefix("[upload] "))
        #expect(e.cause.contains(missing.path))
        #expect(!e.fix.isEmpty)
    } catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageMapsUnknownErrorWithItsText() async {
    struct Boom: Error, CustomStringConvertible { var description: String { "kaboom 42" } }
    do { _ = try await withStage(.finalize) { throw Boom() }; Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("kaboom 42"))
        #expect(e.description.contains(" — "))
    } catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageReturnsValue() async throws {
    #expect(try await withStage(.build) { 7 } == 7)
}

@Test func checkSDKReportsTheCallersStage() {
    do { try Requirements.checkSDK(sdkInfo("18.5"), platform: .ios, stage: .sdk); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sdk) }
    catch { Issue.record("\(error)") }
}
