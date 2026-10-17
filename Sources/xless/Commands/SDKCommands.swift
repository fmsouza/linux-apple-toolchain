import ArgumentParser
import Foundation
import XlessCore
import XlessSDK

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk", abstract: "Manage the Darwin SDK and toolchain metadata.",
        subcommands: {
            #if os(macOS)
            [SDKMetaCommand.self, SDKExportCommand.self, SDKInstallCommand.self]
            #else
            [SDKMetaCommand.self, SDKInstallCommand.self]
            #endif
        }())
}

struct SDKMetaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "meta", abstract: "Write toolchain-meta.json from an Xcode.app.")

    @Option(help: "Path to Xcode.app.") var xcode: String = "/Applications/Xcode.app"
    @Option(help: "Output file.") var out: String = "dist/sdk/toolchain-meta.json"
    @Option(help: "BuildMachineOSBuild value (default: `sw_vers -buildVersion` on macOS).") var buildMachineOSBuild: String?

    func run() async throws {
        let osBuild = try buildMachineOSBuild
            ?? Shell.run("sw_vers", ["-buildVersion"], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try ToolchainMetaCollector.collect(xcodeApp: URL(fileURLWithPath: xcode), buildMachineOSBuild: osBuild)
        for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
        try meta.write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (Xcode \(meta.xcodeVersion) \(meta.xcodeBuild))")
    }
}

#if os(macOS)
struct SDKExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "On the Mac: write toolchain-meta.json and build per-arch Darwin SDKs inside the Linux base image.")

    @Option(help: "Path to Xcode.app.") var xcode: String = "/Applications/Xcode.app"
    @Option(help: "Output directory.") var out: String = "dist/sdk"
    @Option(help: "Base image: '{arch}' in it is replaced by the architecture, else '-<arch>' is appended.") var baseImage: String = "xless-base:local"
    @Option(parsing: .upToNextOption, help: "Docker architectures.") var arch: [String] = ["arm64", "amd64"]

    func run() async throws {
        let outDir = URL(fileURLWithPath: out).standardizedFileURL
        let osBuild = try Shell.run("sw_vers", ["-buildVersion"], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try ToolchainMetaCollector.collect(xcodeApp: URL(fileURLWithPath: xcode), buildMachineOSBuild: osBuild)
        for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
        try meta.write(to: outDir.appendingPathComponent("toolchain-meta.json"))

        for a in arch {
            let image = baseImage.contains("{arch}") ? baseImage.replacingOccurrences(of: "{arch}", with: a) : "\(baseImage)-\(a)"
            let probe = try? Shell.run("docker", ["run", "--rm", "--platform", "linux/\(a)", "-v", "\(xcode):/xcode:ro", image,
                                                  "test", "-d", "/xcode/Contents/Developer"], stage: .sdk)
            guard probe != nil else {
                throw XlessError(.sdk, "the Docker VM cannot see \(xcode)",
                                 fix: "Colima: `colima stop && colima start --mount /Applications:r --mount $HOME:w`; Docker Desktop: add /Applications to File Sharing, or clone Xcode.app under $HOME (cp -cR) and pass --xcode")
            }
            let dir = try Files.fresh(outDir.appendingPathComponent(a))
            try Shell.run("docker", ["run", "--rm", "--platform", "linux/\(a)",
                                     "-v", "\(xcode):/xcode:ro", "-v", "\(dir.path):/out", image,
                                     "xtool", "sdk", "build", "/xcode", "/out"], stage: .sdk, passthrough: true)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("darwin.xtoolsdk").path) else {
                throw XlessError(.sdk, "xtool did not produce \(dir.path)/darwin.xtoolsdk", fix: "see xtool output above")
            }
        }
        print("exported SDK for \(arch.joined(separator: ", ")) to \(outDir.path)")
    }
}
#endif

struct SDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install the Darwin SDK + toolchain metadata on this Linux machine.")

    @Option(help: "darwin.xtoolsdk produced by `xless sdk export` for this machine's architecture.") var xtoolsdk: String?
    @Option(help: "toolchain-meta.json from the same export.") var meta: String?
    @Option(help: "Copy both from an xless SDK image instead (needs docker).") var image: String?

    func run() async throws {
        let fm = FileManager.default
        let metaDest = ToolchainMeta.defaultLocation()
        let sdkDest = DarwinSDKLocator.bundle()
        let sdkParent = sdkDest.deletingLastPathComponent()
        // Everything is staged next to the destinations (same filesystem) and swapped in only after it all succeeded,
        // so a failure leaves any existing SDK and metadata untouched.
        let id = UUID().uuidString
        let sdkStage = sdkParent.appendingPathComponent(".xless-staging-\(id)")
        let metaStage = metaDest.deletingLastPathComponent().appendingPathComponent(".xless-staging-\(id).json")
        defer { try? fm.removeItem(at: sdkStage); try? fm.removeItem(at: metaStage) }

        var stagedBundle: URL
        if let image {
            guard xtoolsdk == nil, meta == nil else {
                throw XlessError(.sdk, "--image cannot be combined with --xtoolsdk/--meta", fix: "pass either --image, or --xtoolsdk with --meta")
            }
            let cid = try Shell.run("docker", ["create", image], stage: .sdk).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { _ = try? Shell.run("docker", ["rm", cid], stage: .sdk) }
            try fm.createDirectory(at: sdkParent, withIntermediateDirectories: true)
            try fm.createDirectory(at: metaDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            stagedBundle = sdkStage
            try Shell.run("docker", ["cp", "\(cid):/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle", sdkStage.path], stage: .sdk)
            try Shell.run("docker", ["cp", "\(cid):/opt/xless/toolchain-meta.json", metaStage.path], stage: .sdk)
        } else {
            guard let xtoolsdk, let meta else {
                throw XlessError(.sdk, "pass --xtoolsdk and --meta, or --image", fix: "see docs/README.md#native-install")
            }
            for (name, path) in [("--xtoolsdk", xtoolsdk), ("--meta", meta)] where !fm.fileExists(atPath: path) {
                throw XlessError(.sdk, "\(name) \(path) does not exist", fix: "pass the files produced by `xless sdk export`")
            }
            _ = try ToolchainMeta.load(from: URL(fileURLWithPath: meta))
            try fm.createDirectory(at: sdkParent, withIntermediateDirectories: true)
            try fm.createDirectory(at: metaDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // `xtool sdk install` deletes an existing SDK before installing, so run it against a private config root.
            try Shell.run("xtool", ["sdk", "install", xtoolsdk], env: ["XDG_CONFIG_HOME": sdkStage.path], stage: .sdk, passthrough: true)
            stagedBundle = DarwinSDKLocator.bundle(env: ["XDG_CONFIG_HOME": sdkStage.path])
            try fm.copyItem(at: URL(fileURLWithPath: meta), to: metaStage)
        }
        _ = try ToolchainMeta.load(from: metaStage)
        guard fm.fileExists(atPath: stagedBundle.path) else {
            throw XlessError(.sdk, "no darwin.artifactbundle was produced", fix: "check the SDK source and rerun")
        }
        try swap(stagedBundle, into: sdkDest)
        try swap(metaStage, into: metaDest)
        print("SDK at \(sdkDest.path); metadata at \(metaDest.path)")
    }

    private func swap(_ staged: URL, into dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: dest)
        }
    }
}
