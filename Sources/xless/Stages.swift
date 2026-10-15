import Foundation
import XlessASC
import XlessAssets
import XlessBuild
import XlessCore
import XlessFinalize
import XlessPackage
import XlessSign
import XlessTauri

/// One function per stage. Each runs inside `withStage`, so every failure (including raw App Store Connect,
/// network and file errors) prints `[stage] cause — fix` and exits with that stage's code.
enum StageRunner {
    /// Tauri overlays only: contract and script checks, the work copy and the toolchains the build needs.
    static func prepare(_ ctx: Context) async throws -> String {
        guard let tauri = ctx.tauriBuild else { return "skipped (not a Tauri project)" }
        return try await TauriBuilder.prepare(ctx: tauri).path
    }

    static func build(_ ctx: Context) async throws -> URL {
        if let tauri = ctx.tauriBuild { return try await TauriBuilder.build(ctx: tauri) }
        return try await withStage(.build) {
            switch ctx.platform {
            case .ios: return try IOSBuilder.build(project: ctx.project, config: ctx.config, paths: ctx.paths)
            case .macos: return try MacBuilder.build(project: ctx.project, config: ctx.config, paths: ctx.paths)
            }
        }
    }

    static func assets(_ ctx: Context) async throws -> URL {
        try await withStage(.assets) {
            let input = try ctx.paths.bundle(in: ctx.paths.app, stage: .assets)
            return try await AssetsStage.run(input: input, outputDir: ctx.paths.assets, platform: ctx.platform, config: ctx.config, project: ctx.project)
        }
    }

    static func finalize(_ ctx: Context) async throws -> URL {
        try await withStage(.finalize) {
            let input = try ctx.paths.bundle(in: ctx.paths.assets, stage: .finalize)
            let meta = try ToolchainMeta.load(from: ToolchainMeta.defaultLocation())
            return try Finalizer.run(input: input, outputDir: ctx.paths.final, platform: ctx.platform, config: ctx.config, meta: meta)
        }
    }

    static func sign(_ ctx: Context) async throws -> URL {
        try await withStage(.sign) {
            let input = try ctx.paths.bundle(in: ctx.paths.final, stage: .sign)
            let client = ASCClient(credentials: try ASCCredentials.fromSecrets(ctx.secrets, stage: .sign))
            return try await SignStage.run(input: input, outputDir: ctx.paths.signed, platform: ctx.platform, config: ctx.config,
                                           project: ctx.project, secrets: ctx.secrets, client: client)
        }
    }

    static func package(_ ctx: Context) async throws -> URL {
        try await withStage(.package) {
            let input = try ctx.paths.bundle(in: ctx.paths.signed, stage: .package)
            switch ctx.platform {
            case .ios: return try Packager.ipa(signedApp: input, outputDir: ctx.paths.out)
            case .macos: return try Packager.notarizedZip(signedApp: input, outputDir: ctx.paths.out, secrets: ctx.secrets)
            }
        }
    }

    struct UploadOutcome {
        var record: UploadRecord
        /// Present when xless.yml has a `testflight:` block.
        var testflight: TestFlightResult?

        /// Terminal output: the build line, then the TestFlight delivery summary when configured (warnings go to stderr).
        func report() -> String {
            "build \(record.buildID ?? "?") \(record.processingState ?? record.state)"
                + (testflight.map { "\n" + $0.summary.joined(separator: "\n") } ?? "")
        }
    }

    static func upload(_ ctx: Context) async throws -> UploadOutcome {
        try await withStage(.upload) {
            guard ctx.platform == .ios else {
                throw XlessError(.upload, "upload is App Store only; macOS Developer ID builds are distributed directly", fix: "use the notarized zip from `xless package --platform macos`")
            }
            let ipas = ((try? FileManager.default.contentsOfDirectory(at: ctx.paths.out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "ipa" }
            let product = try ctx.config.platform(.ios).product
            guard !ipas.isEmpty else { throw XlessError(.upload, "no .ipa in \(ctx.paths.out.path)", fix: "run `xless package --platform ios` first") }
            let matching = ipas.first { $0.deletingPathExtension().lastPathComponent == product }
            guard let ipa = matching ?? (ipas.count == 1 ? ipas[0] : nil) else {
                throw XlessError(.upload, "multiple .ipa files in \(ctx.paths.out.path) and none is named \(product).ipa",
                                 fix: "remove stale .ipa files, or run `xless package --platform ios` again")
            }
            // Declare what the ipa carries, not the current config: the build number is re-resolved on every run.
            let versions = try IPAInfo.uploadVersions(ipa: ipa, buildOverride: ctx.buildOverride)
            let client = ASCClient(credentials: try ASCCredentials.fromSecrets(ctx.secrets, stage: .upload))
            let recordURL = ctx.paths.uploadRecord
            try? FileManager.default.removeItem(at: recordURL)
            let record = try await BuildUploader(client: client).upload(ipa: ipa, bundleID: ctx.config.bundleID(for: .ios),
                                                                  version: versions.version, build: versions.build, platform: .ios) { record in
                // Written on every state change, so the build ID survives a processing failure or timeout.
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(record).write(to: recordURL, options: .atomic)
            }
            guard let tf = ctx.config.testflight, let buildID = record.buildID else { return UploadOutcome(record: record, testflight: nil) }
            let result = try await TestFlightPublisher(client: client).publish(
                bundleID: ctx.config.bundleID(for: .ios), buildID: buildID, buildNumber: versions.build, config: tf)
            for w in result.warnings { FileHandle.standardError.write(Data((w + "\n").utf8)) }
            return UploadOutcome(record: record, testflight: result)
        }
    }
}
