import ArgumentParser
import XlessASC
import XlessCore

extension Stage: ExpressibleByArgument {}

struct ShipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ship", abstract: "Run [prepare →] build → assets → finalize → sign → package → upload (upload: iOS only); --from/--to select a range.")
    @OptionGroup var options: ProjectOptions
    @Option(help: "Resume from this stage.") var from: Stage = .build
    @Option(help: "Stop after this stage (default: upload, or package for macOS).") var to: Stage = .upload

    func validate() throws {
        let stages = "use one of: prepare, build, assets, finalize, sign, package, upload"
        for (flag, stage) in [("--from", from), ("--to", to)] where [.ib, .config, .sdk].contains(stage) {
            throw ValidationError("\(flag) \(stage.rawValue): `\(stage.rawValue)` is not a ship pipeline stage; \(stages)")
        }
        if to < from { throw ValidationError("--to \(to.rawValue) comes before --from \(from.rawValue)") }
    }

    func run() async throws {
        let ctx = try await Context.load(options, fresh: DatedBuildNumber.isFreshRun(command: "ship", from: from))
        let steps: [(Stage, () async throws -> String)] = [
            (.prepare, { try await StageRunner.prepare(ctx) }),
            (.build, { try await StageRunner.build(ctx).path }),
            (.assets, { try await StageRunner.assets(ctx).path }),
            (.finalize, { try await StageRunner.finalize(ctx).path }),
            (.sign, { try await StageRunner.sign(ctx).path }),
            (.package, { try await StageRunner.package(ctx).path }),
            (.upload, { try await StageRunner.upload(ctx).report() }),
        ]
        // A Tauri build without a freshly synced work copy is never right: starting at build includes prepare.
        let start: Stage = from == .build && ctx.tauri != nil ? .prepare : from
        for (stage, step) in steps where stage >= start && stage <= to {
            if stage == .upload, ctx.platform == .macos { continue }
            if stage == .prepare, ctx.tauri == nil { continue }
            print("==> \(stage.rawValue)")
            print(try await step())
        }
    }
}
