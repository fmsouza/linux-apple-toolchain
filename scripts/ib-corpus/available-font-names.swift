// Prints the fonts CoreText reports as available (CTFontManagerCopyAvailablePostScriptNames) whose file lies in the
// operating system's /System tree, one "<PostScript name>\t<family name>" line each, sorted. Public CoreText calls
// only; nothing but names is read.
//
// Run on the Mac with `swift`, and inside the iOS simulator runtime as an iphonesimulator build started with
// `xcrun simctl spawn` (scripts/ib-corpus/known-fonts.sh does both). This catches names that are not in any font
// file's name table, such as the PingFang* aliases of the dot-named faces in FontServices' PingFangUI.ttc.
import CoreText
import Foundation

var lines = Set<String>()
for name in CTFontManagerCopyAvailablePostScriptNames() as! [String] {
    let d = CTFontDescriptorCreateWithNameAndSize(name as CFString, 0)
    guard let path = (CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL)?.path,
          path.hasPrefix("/System/") || path.contains("/RuntimeRoot/System/") else { continue }
    let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String ?? ""
    lines.insert("\(name)\t\(family)")
}
print(lines.sorted().joined(separator: "\n"))
