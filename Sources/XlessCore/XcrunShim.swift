import Foundation

/// Answers the `xcrun` calls that cargo build scripts make (cc crate, etc.) on Linux. Anything else is refused loudly.
public enum XcrunShim {
    public struct Unsupported: Error, CustomStringConvertible {
        public let argv: [String]
        public var description: String { "xcrun shim: unsupported call: xcrun \(argv.joined(separator: " "))" }
    }

    /// Darwin tool name → Linux executable (resolved through `which`). `ld` maps to the SDK's ld64.lld.
    static let toolMap = ["clang": "clang", "clang++": "clang++", "cc": "clang", "c++": "clang++",
                          "nm": "llvm-nm", "ar": "llvm-ar", "ranlib": "llvm-ranlib", "libtool": "llvm-libtool-darwin",
                          "lipo": "llvm-lipo", "strip": "llvm-strip", "otool": "llvm-otool", "swift": "swift", "swiftc": "swiftc"]

    public static func run(_ args: [String], sdk: DarwinSDK, which: (String) -> String?) throws -> String {
        var rest = args[...]
        var sdkName = "iphoneos"   // default for our use: iOS builds
        while let a = rest.first {
            switch a {
            case "--sdk", "-sdk":
                rest = rest.dropFirst()
                guard let n = rest.first, DarwinSDK.platformDir[n] != nil else { throw Unsupported(argv: args) }
                sdkName = n; rest = rest.dropFirst()
            case "--show-sdk-path", "-show-sdk-path":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return try sdk.sdkPath(sdkName).path + "\n"
            case "--show-sdk-version", "-show-sdk-version":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return try sdk.sdkVersion(sdkName) + "\n"
            case "--show-sdk-platform-path", "-show-sdk-platform-path":
                guard rest.count == 1 else { throw Unsupported(argv: args) }
                return try sdk.sdkPath(sdkName).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "\n"
            case "--find", "-find", "-f":
                rest = rest.dropFirst()
                guard let tool = rest.first, rest.count == 1 else { throw Unsupported(argv: args) }
                if tool == "ld" || tool == "ld64" { return sdk.ld64.path + "\n" }
                guard let linux = toolMap[tool], let path = which(linux) else { throw Unsupported(argv: args) }
                return path + "\n"
            default:
                throw Unsupported(argv: args)
            }
        }
        throw Unsupported(argv: args)
    }
}
