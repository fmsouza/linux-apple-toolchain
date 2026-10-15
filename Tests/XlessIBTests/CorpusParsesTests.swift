import Foundation
import Testing
import XlessCore
@testable import XlessIB

/// Corpus cases the parser is expected to reject (case → error cause). Empty: every corpus storyboard parses.
private let expectedRejections: [String: String] = [:]

private func corpusStoryboards() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: corpusRoot, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "storyboard" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func corpusIsLarge() throws {
    #expect(try corpusStoryboards().count >= 60)
}

@Test(arguments: try corpusStoryboards())
func corpusStoryboardParses(_ url: URL) throws {
    let name = url.deletingPathExtension().lastPathComponent
    if let message = expectedRejections[name] {
        let error = #expect(throws: XlessError.self) { try StoryboardParser.parse(url: url) }
        #expect(error?.cause == message)
        return
    }
    let doc = try StoryboardParser.parse(url: url)
    #expect(!doc.scenes.isEmpty)
    #expect(doc.scenes.contains { $0.viewController.id == doc.initialViewController })
}

@Test func everyExpectedRejectionIsACorpusCase() throws {
    let names = Set(try corpusStoryboards().map { $0.deletingPathExtension().lastPathComponent })
    for name in expectedRejections.keys { #expect(names.contains(name), "stale entry \(name)") }
}

@Test func corpusElementFormsMapLikeAttributes() throws {
    let multi = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("label-multiline-text.storyboard"))
    #expect(multi.scenes[0].viewController.view.subviews[0].text == "Line one\nLine two")
    let ref = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("image-reference.storyboard"))
    let attr = try StoryboardParser.parse(url: corpusRoot.appendingPathComponent("image-catalog-scaleAspectFit.storyboard"))
    #expect(ref.scenes[0].viewController.view.subviews[0].image == IBImageReference(name: "Logo", catalog: nil))
    #expect(ref.scenes[0].viewController.view.subviews[0].image == attr.scenes[0].viewController.view.subviews[0].image)
}
