import ArgumentParser
import XlessCore

extension Stage: ExpressibleByArgument {}

struct ShipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ship", abstract: "Run build → assets → finalize → sign → package → upload (upload: iOS only).")
    @OptionGroup var options: ProjectOptions
    @Option(help: "Resume from this stage.") var from: Stage = .build

    func validate() throws {
        if from == .ib {
            throw ValidationError("`ib` is not a ship pipeline stage; use one of: build, assets, finalize, sign, package, upload")
        }
    }

    func run() async throws {
        let ctx = try Context.load(options)
        let steps: [(Stage, () async throws -> String)] = [
            (.build, { try await StageRunner.build(ctx).path }),
            (.assets, { try await StageRunner.assets(ctx).path }),
            (.finalize, { try await StageRunner.finalize(ctx).path }),
            (.sign, { try await StageRunner.sign(ctx).path }),
            (.package, { try await StageRunner.package(ctx).path }),
            (.upload, { try await StageRunner.upload(ctx).report() }),
        ]
        for (stage, step) in steps where stage >= from {
            if stage == .upload, ctx.platform == .macos { continue }
            print("==> \(stage.rawValue)")
            print(try await step())
        }
    }
}
