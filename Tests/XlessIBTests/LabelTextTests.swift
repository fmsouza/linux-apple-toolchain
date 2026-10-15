import Testing
import Foundation
@testable import XlessIB

/// The `UIText` strings of the labels in the view nib that xless compiles for a corpus case, in label order.
private func compiledLabelTexts(_ name: String) throws -> (texts: [String?], dump: String) {
    let r = try StoryboardCompiler.compile(url: CorpusCase(name: name).storyboard, options: .flagset(named: "universal-16", root: corpusRoot))
    let nib = try #require(r.files.first { $0.key.contains("-view-") }?.value)
    let a = try NIBArchiveReader.read(nib)
    func values(_ o: NIBObject) -> [(String, NIBValueData)] {
        a.values[o.valuesStart..<(o.valuesStart + o.valueCount)].map { (String(decoding: a.keys[$0.keyIndex], as: UTF8.self), $0.data) }
    }
    let texts: [String?] = try a.objects.filter { a.classNames[$0.classNameIndex].string == "UILabel" }.map { label in
        let text = try #require(values(label).first { $0.0 == "UIText" }?.1)
        guard case .object(let r) = text else { return nil }
        let object = values(a.objects[Int(r)])
        guard object.count == 1, object[0].0 == "NS.bytes", case NIBValueData.data(let bytes) = object[0].1 else {
            Issue.record("UIText of \(name) is not an NSString: \(object)"); return nil
        }
        let string = String(decoding: bytes, as: UTF8.self)
        #expect(Data(string.utf8) == bytes, "UIText of \(name) is not valid UTF-8")
        return string
    }
    return (texts, NIBDump.render(a))
}

/// Plan Review Focus #1: non-ASCII text is stored exactly as ibtool stores it (UTF-8, no BOM, entities decoded).
@Test func labelUnicodeRoundTripsThroughNIBDump() throws {
    let expected = "Olá — 日本語 🚀 \"q\" & <x>"
    let (texts, dump) = try compiledLabelTexts("label-unicode")
    #expect(texts == [expected])
    // The dump shows the decoded string, so a regression prints what xless stored instead.
    #expect(dump.contains(#"NS.bytes = data[33] "# + Data(expected.utf8).map { String(format: "%02x", $0) }.joined() + #" "Olá — 日本語 🚀 \"q\" & <x>""#), "\(dump)")
}

@Test func labelTextFormsKeepEveryCodePoint() throws {
    let (texts, _) = try compiledLabelTexts("label-text-forms")
    let strings = texts.compactMap { $0 }
    // right-to-left and mixed scripts, emoji sequences and astral code points, as written
    for t in ["مرحبا بالعالم", "שלום עולם", "Hello עולם 123", "👩‍💻 🇧🇷 👍🏽", "𠀀𝄞", "a\u{2028}b", "a\u{2029}b", "a\u{85}b"] {
        #expect(strings.contains { $0.unicodeScalars.elementsEqual(t.unicodeScalars) }, "\(t)")
    }
    // NFC and NFD stay apart (Swift's String == would merge them)
    let cafe = strings.filter { $0 == "Café" }.map { Array($0.utf8) }
    #expect(cafe.count == 2 && Set(cafe).count == 2, "\(cafe)")
    // leading U+FEFF dropped, later ones kept; tab, newline (from &#10; and a <string> CR LF) and spaces kept
    // a literal TAB and LF inside the attribute are spaces after XML attribute-value normalization ("lit tab lf")
    for t in ["BOM", "x", "", "mid\u{FEFF}dle", " a \u{FEFF}", "tab\there", "a\nb", "One\nTwo", "  padded  ", "  ", "lit tab lf"] {
        #expect(strings.contains { $0.unicodeScalars.elementsEqual(t.unicodeScalars) }, "\(t.debugDescription)")
    }
}

@Test func normalizedTextDropsOnlyLeadingByteOrderMarks() {
    #expect(LabelRule.normalizedText("\u{FEFF}\u{FEFF}x\u{FEFF}") == "x\u{FEFF}")
    #expect(LabelRule.normalizedText("\u{FEFF}") == "")
    #expect(Array(LabelRule.normalizedText("Cafe\u{301}").unicodeScalars) == Array("Cafe\u{301}".unicodeScalars))
}

/// Equal strings are shared byte for byte, not by Unicode equivalence (`label-text-forms`).
@Test func archiveBuilderSharesStringsByBytes() {
    let b = ArchiveBuilder()
    #expect(b.string("Caf\u{E9}") != b.string("Cafe\u{301}"))
    #expect(b.string("Same") == b.string("Same"))
}
