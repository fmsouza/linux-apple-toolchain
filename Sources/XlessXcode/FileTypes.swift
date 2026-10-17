import Foundation

/// Xcode file type identifiers by extension, for the files React Native / Expo / CocoaPods projects reference. The
/// identifiers are the ones Swift Build's own file type specs define (`StandardFileTypes.xcspec`,
/// `AppleFileTypes.xcspec`, …). Used when a pbxproj names no usable type (the `xcode` npm package writes
/// `lastKnownFileType = unknown` / `explicitFileType = undefined`).
enum FileTypes {
    static let byExtension: [String: String] = [
        "swift": "sourcecode.swift",
        "m": "sourcecode.c.objc",
        "mm": "sourcecode.cpp.objcpp",
        "c": "sourcecode.c.c",
        "cc": "sourcecode.cpp.cpp", "cpp": "sourcecode.cpp.cpp", "cxx": "sourcecode.cpp.cpp",
        "h": "sourcecode.c.h",
        "hh": "sourcecode.cpp.h", "hpp": "sourcecode.cpp.h", "hxx": "sourcecode.cpp.h",
        "s": "sourcecode.asm",
        "modulemap": "sourcecode.module-map",
        "metal": "sourcecode.metal",
        "js": "sourcecode.javascript",
        "json": "text.json",
        "plist": "text.plist.xml",
        "entitlements": "text.plist.entitlements",
        "strings": "text.plist.strings",
        "stringsdict": "text.plist.stringsdict",
        "xcstrings": "text.json.xcstrings",
        "xcprivacy": "text.xml",
        "xml": "text.xml",
        "txt": "text",
        "md": "net.daringfireball.markdown",
        "sh": "text.script.sh",
        "rb": "text.script.ruby",
        "py": "text.script.python",
        "xcconfig": "text.xcconfig",
        "xcfilelist": "text.xcfilelist",
        "storyboard": "file.storyboard",
        "xib": "file.xib",
        "xcassets": "folder.assetcatalog",
        "png": "image.png", "jpg": "image.jpeg", "jpeg": "image.jpeg", "gif": "image.gif", "pdf": "image.pdf",
        "ttf": "file", "otf": "file",
        "a": "archive.ar",
        "tbd": "sourcecode.text-based-dylib-definition",
        "dylib": "compiled.mach-o.dylib",
        "framework": "wrapper.framework",
        "xcframework": "wrapper.xcframework",
        "bundle": "wrapper.plug-in",
        "app": "wrapper.application",
        "appex": "wrapper.app-extension",
        "xcodeproj": "wrapper.pb-project",
        "xcdatamodeld": "wrapper.xcdatamodeld",
        "lproj": "folder",
    ]

    static func infer(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? "file"
    }

    /// A pbxproj type value Xcode itself accepts (the `xcode` npm package writes `undefined`/`unknown`).
    static func isKnown(_ type: String) -> Bool {
        !type.isEmpty && type != "undefined" && type != "unknown"
    }
}
