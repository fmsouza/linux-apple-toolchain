import ArgumentParser
import XlessCore

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build an unsigned .app into .xless/build/<platform>/app.")
    @OptionGroup var options: ProjectOptions
    func run() async throws {
        let app = try await StageRunner.build(Context.load(options))
        print(app.path)
    }
}

struct AssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "assets", abstract: "Compile the asset catalog into the bundle (.xless/build/<platform>/assets).")
    @OptionGroup var options: ProjectOptions
    func run() async throws { print(try await StageRunner.assets(Context.load(options)).path) }
}

struct FinalizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "finalize", abstract: "Stamp Xcode metadata and patch binaries (.xless/build/<platform>/final).")
    @OptionGroup var options: ProjectOptions
    func run() async throws { print(try await StageRunner.finalize(Context.load(options)).path) }
}

struct PackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "package", abstract: "Create the .ipa (iOS) or notarized .zip (macOS) in .xless/build/<platform>/out.")
    @OptionGroup var options: ProjectOptions
    func run() async throws { print(try await StageRunner.package(Context.load(options)).path) }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload the .ipa to App Store Connect and wait for TestFlight processing.")
    @OptionGroup var options: ProjectOptions
    func run() async throws {
        print(try await StageRunner.upload(Context.load(options)).report())
    }
}
