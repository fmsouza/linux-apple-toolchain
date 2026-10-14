import ArgumentParser
import Foundation
import XlessCore

@main
enum Main {
    static func main() async {
        do {
            var command = try Xless.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as XlessError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exit(error.stage.exitCode)
        } catch {
            Xless.exit(withError: error)
        }
    }
}
