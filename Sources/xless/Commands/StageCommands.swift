import ArgumentParser
import XlessASC
import XlessCore

struct PrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prepare", abstract: "Tauri overlays: check the project, sync the work copy, install dependencies and toolchains.")
    @OptionGroup var options: ProjectOptions
    func run() async throws { print(try await StageRunner.prepare(Context.load(options, fresh: DatedBuildNumber.isFreshRun(command: "prepare")))) }
}

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build an unsigned .app into .xless/build/<platform>/app (Tauri overlays: after prepare).")
    @OptionGroup var options: ProjectOptions
    func run() async throws {
        let ctx = try await Context.load(options, fresh: DatedBuildNumber.isFreshRun(command: "build"))
        if ctx.tauri != nil { _ = try await StageRunner.prepare(ctx) }
        print(try await StageRunner.build(ctx).path)
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
