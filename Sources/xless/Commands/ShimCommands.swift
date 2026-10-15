import ArgumentParser
import Foundation
import XlessCore

struct ShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shim", abstract: "Xcode tool shims for Linux builds (internal).",
                                                    shouldDisplay: false, subcommands: [XcrunShimCommand.self])
}

struct XcrunShimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "xcrun")
    @Argument(parsing: .captureForPassthrough) var args: [String] = []
    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let shimDir = env["XLESS_SHIM_DIR"]
        let which: (String) -> String? = { name in
            for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) where dir != shimDir {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            return nil
        }
        do { print(try XcrunShim.run(args, sdk: DarwinSDK(), which: which), terminator: "") }
        catch let e as XcrunShim.Unsupported { FileHandle.standardError.write(Data("\(e)\n".utf8)); Foundation.exit(70) }
    }
}
