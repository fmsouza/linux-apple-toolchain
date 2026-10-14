import ArgumentParser
import Foundation
import XlessCore
import XlessFinalize

struct InspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Print Info.plist and Mach-O build versions of a bundle as JSON.")
    @Argument var bundle: String
    @Option var platform: Platform
    func run() async throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(Inspector.report(bundle: URL(fileURLWithPath: bundle), platform: platform)), as: UTF8.self))
    }
}
