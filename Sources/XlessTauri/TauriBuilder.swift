import Foundation
import XlessCore

/// What the Tauri stages need from the CLI's context.
public struct TauriBuildContext: Sendable {
    public var overlay: TauriOverlay
    public var resolved: ResolvedTauri
    public var sourceRoot: URL
    public var workRoot: URL
    public var paths: StagePaths
    public var sdk: DarwinSDK
    public var env: [String: String]

    public init(overlay: TauriOverlay, resolved: ResolvedTauri, sourceRoot: URL, workRoot: URL, paths: StagePaths,
                sdk: DarwinSDK = DarwinSDK(), env: [String: String] = ProcessInfo.processInfo.environment) {
        self.overlay = overlay; self.resolved = resolved; self.sourceRoot = sourceRoot; self.workRoot = workRoot
        self.paths = paths; self.sdk = sdk; self.env = env
    }

    var tauriDir: URL { workRoot.appendingPathComponent(resolved.tauriDir, isDirectory: true) }
    /// The Tauri app root (the parent of the Tauri directory), where tauri-cli runs the frontend and cargo.
    var appRoot: URL { tauriDir.deletingLastPathComponent() }
    var appleDir: URL { workRoot.appendingPathComponent(resolved.appleDir, isDirectory: true) }
    var cargoHome: String { env["CARGO_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (env["HOME"] ?? NSHomeDirectory()) + "/.cargo" }
    /// Child-process additions: rustup's bin dir first on PATH (rustup-init may have just created it), no corepack prompt.
    var tools: [String: String?] {
        ["PATH": "\(cargoHome)/bin:\(env["PATH"] ?? "/usr/bin:/bin")", "COREPACK_ENABLE_DOWNLOAD_PROMPT": "0"]
    }
}

/// The `prepare` and `build` stages for `type: tauri` overlays: what `tauri ios build` and Xcode do on a Mac, re-done
/// on Linux without either. Sequence and settings: docs/research/tauri-ios-contract.md, "Linux build — spike A
/// findings" and "spike B findings" (scripts/spikes/hellotauri-linux.sh is the hand-run version).
public enum TauriBuilder {
    /// Checks the project (contract versions, build scripts), then syncs the work copy and installs what the build
    /// needs: binary dependencies, JS packages and the app's Rust toolchain with the iOS target and llvm-tools.
    @discardableResult
    public static func prepare(ctx: TauriBuildContext) async throws -> URL {
        try await withStage(.prepare) {
            let r = ctx.resolved
            try TauriContract.check(source: ctx.sourceRoot, tauriDir: r.tauriDir)
            let scripts = try ScriptPolicy.check(target: r.target, overlay: ctx.overlay)
            for (name, handling) in scripts.sorted(by: { $0.key < $1.key }) {
                log("project.yml script '\(name)': \(handling)\(handling == "built-in" ? " — \(ScriptPolicy.builtInNote)" : "")")
            }

            log("syncing \(ctx.sourceRoot.path) → \(ctx.workRoot.path)")
            // In docker every source is mounted at /source; scripts/testflight.sh names the host path in XLESS_SOURCE_ORIGIN.
            let origin = ctx.env["XLESS_SOURCE_ORIGIN"].flatMap { $0.isEmpty ? nil : $0 }
            let count = try WorkCopy.sync(source: ctx.sourceRoot, to: ctx.workRoot, origin: origin, baseEnvironment: ctx.env)
            log("\(count) tracked files")
            if !ctx.overlay.binaryDependencies.isEmpty {
                let cache = ctx.env["XLESS_CACHE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                    ?? URL(fileURLWithPath: (ctx.env["HOME"] ?? NSHomeDirectory()) + "/.cache/xless")
                log("installing \(ctx.overlay.binaryDependencies.count) binary dependencies")
                try BinaryDeps.install(ctx.overlay.binaryDependencies, into: ctx.workRoot, cache: cache.appendingPathComponent("downloads"))
            }
            if let install = try installCommand(appRoot: ctx.appRoot) {
                log("\(install.arguments.joined(separator: " ")) (\(install.lockfile))")
                try run(install.arguments, cwd: ctx.appRoot, env: ctx.tools, ctx: ctx, stage: .prepare)
            }
            try bootstrapRust(ctx)
            return ctx.workRoot
        }
    }

    /// rustup itself (`rustup-init` when missing), then `rustupSteps`.
    static func bootstrapRust(_ ctx: TauriBuildContext) throws {
        if (try? Shell.run("sh", ["-c", "command -v rustup"], env: ctx.tools, baseEnvironment: ctx.env, stage: .prepare)) == nil {
            log("rustup-init (toolchains in \(ctx.env["RUSTUP_HOME"] ?? "~/.rustup"))")
            try run(["rustup-init", "-y", "--no-modify-path", "--default-toolchain", "none"], cwd: nil, env: ctx.tools, ctx: ctx, stage: .prepare)
        }
        let fm = FileManager.default
        var dir = ctx.tauriDir.standardizedFileURL
        let root = ctx.workRoot.standardizedFileURL.path
        var toolchainFile = false
        while dir.path.hasPrefix(root) {
            if ["rust-toolchain.toml", "rust-toolchain"].contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { toolchainFile = true; break }
            if dir.path == root { break }
            dir = dir.deletingLastPathComponent()
        }
        let active = toolchainFile || (try? Shell.run("rustup", ["show", "active-toolchain"], cwd: ctx.tauriDir, env: ctx.tools,
                                                      baseEnvironment: ctx.env, stage: .prepare)) != nil
        for step in rustupSteps(toolchainFile: toolchainFile, activeToolchain: active) {
            try run(step, cwd: ctx.tauriDir, env: ctx.tools, ctx: ctx, stage: .prepare)
        }
    }

    /// The toolchain `rust-toolchain.toml` selects; without one (apps from `tauri create`), stable, made the default when
    /// nothing else is. Then, because an app's toolchain file need not list them, the iOS target and `llvm-tools`
    /// (spike B difference 1).
    static func rustupSteps(toolchainFile: Bool, activeToolchain: Bool) -> [[String]] {
        var steps = [toolchainFile ? ["rustup", "toolchain", "install"] : ["rustup", "toolchain", "install", "stable", "--profile", "minimal"]]
        if !toolchainFile && !activeToolchain { steps.append(["rustup", "default", "stable"]) }
        return steps + [["rustup", "target", "add", TauriEnvironment.target], ["rustup", "component", "add", "llvm-tools"]]
    }

    /// The frozen install for the app root's lockfile; nil without a package.json.
    static func installCommand(appRoot: URL) throws -> (arguments: [String], lockfile: String)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appRoot.appendingPathComponent("package.json").path) else { return nil }
        let managers: [(String, [String])] = [
            ("package-lock.json", ["npm", "ci"]),
            ("pnpm-lock.yaml", ["corepack", "pnpm", "install", "--frozen-lockfile"]),
            ("yarn.lock", ["corepack", "yarn", "install", "--frozen-lockfile"]),
        ]
        let present = managers.filter { fm.fileExists(atPath: appRoot.appendingPathComponent($0.0).path) }
        guard present.count == 1 else {
            throw XlessError(.prepare, present.isEmpty
                                ? "package.json in \(appRoot.path) has no lockfile"
                                : "several JS lockfiles in \(appRoot.path): \(present.map(\.0).joined(separator: ", "))",
                             fix: present.isEmpty ? "commit the lockfile of your package manager (pnpm-lock.yaml, package-lock.json or yarn.lock)"
                                                  : "keep only the lockfile of the package manager the app uses")
        }
        return (present[0].1, present[0].0)
    }

    // MARK: build

    /// Frontend, cargo (staticlib), the Swift aggregate, the app's native sources, the link and the `.app`. Returns the
    /// `.app` in `ctx.paths.app`.
    public static func build(ctx: TauriBuildContext) async throws -> URL {
        try await withStage(.build) {
            let r = ctx.resolved, work = ctx.workRoot, apple = ctx.appleDir
            let ios = try r.config.platform(.ios), minOS = ios.minimumOS
            let sdkRoot = try ctx.sdk.sdkPath("iphoneos")
            let target = TauriEnvironment.target

            // 1. Frontend, as tauri-cli runs it: `sh -c` in the app root with the hook env.
            if let before = beforeBuildCommand(r.tauri) {
                let cwd = before.cwd.map { ctx.appRoot.appendingPathComponent($0) } ?? ctx.appRoot
                log("beforeBuildCommand: \(before.script)")
                var env = ctx.tools
                for (k, v) in try TauriEnvironment.frontend(sdk: ctx.sdk) { env[k] = v }
                try run(["sh", "-c", before.script], cwd: cwd, env: env, ctx: ctx, stage: .build)
            }
            if let dist = r.tauri.frontendDist, !dist.contains("://") {
                let url = ctx.tauriDir.appendingPathComponent(dist).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw XlessError(.build, "frontendDist \(dist) (\(url.path)) does not exist after beforeBuildCommand",
                                     fix: "check that build.beforeBuildCommand in tauri.conf.json writes the frontend to build.frontendDist")
                }
            }

            // 2. cargo: the app crate as a staticlib only (open question 3).
            let manifest = ctx.tauriDir.appendingPathComponent("Cargo.toml")
            let metadata = try Shell.run("cargo", ["metadata", "--format-version", "1", "--filter-platform", target, "--manifest-path", manifest.path],
                                         cwd: ctx.appRoot, env: ctx.tools, baseEnvironment: ctx.env, stage: .build).stdout
            let crate = try rootCrate(metadata: Data(metadata.utf8), manifest: manifest)
            try TauriEnvironment.writeLinkerWrapper(minOS: minOS, sdk: ctx.sdk, workRoot: work)
            var cargoEnv = ctx.tools
            for (k, v) in try TauriEnvironment.cargo(resolved: r, overlay: ctx.overlay, sdk: ctx.sdk, workRoot: work) { cargoEnv[k] = v }
            let features = (ctx.overlay.features + ["tauri/custom-protocol"]).joined(separator: " ")
            log("cargo rustc --package \(crate.package) --features \"\(features)\" --crate-type staticlib")
            try run(["cargo", "rustc", "--package", crate.package, "--manifest-path", manifest.path, "--target", target,
                     "--features", features, "--lib", "--release", "--crate-type", "staticlib"],
                    cwd: ctx.appRoot, env: cargoEnv, ctx: ctx, stage: .build)
            let cargoOut = crate.targetDir.appendingPathComponent("\(target)/release", isDirectory: true)
            let staticLib = cargoOut.appendingPathComponent("lib\(crate.lib).a")

            // 3. A Linux-built staticlib has no Swift objects; one that has was built on a Mac.
            let nm = try rustLLVMTool("llvm-nm", ctx), objdump = try rustLLVMTool("llvm-objdump", ctx)
            try SwiftPackages.checkNoSwiftObjects(staticLib: staticLib, objdump: objdump)

            // 4. Search paths: cargo's output dir first (the staticlib is linked in place as -l<crate lib>, not copied to
            // Externals/…/libapp.a as xcode-script does), then the project's LIBRARY_SEARCH_PATHS entries that exist
            // (contract, "Fixes the Mac line needed on Linux").
            let vars = try settingsVariables(resolved: r, workRoot: work, sdk: ctx.sdk)
            let fm = FileManager.default
            let searchPaths = [cargoOut.path] + NativeLink.expandSettings(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: r.target.settings) ?? "", vars: vars)
                .filter { fm.fileExists(atPath: $0) && $0 != cargoOut.path }

            // 5. Every Swift package of the app as one static library.
            let (api, plugins) = try SwiftPackages.discover(metadata: Data(metadata.utf8))
            let swiftDir = work.appendingPathComponent(".xless/swift", isDirectory: true)
            log("Swift packages: Tauri\(plugins.map { ", \($0.name)" }.joined())")
            let staged = try SwiftPackages.stage(tauriAPI: api, plugins: plugins, into: swiftDir)
            let aggregate = try SwiftPackages.writeAggregate(minimumIOS: minOS, plugins: staged, into: swiftDir)
            var swiftEnv = ctx.env
            if case let path?? = ctx.tools["PATH"] { swiftEnv["PATH"] = path }
            let swiftLib = try SwiftPackages.build(aggregateDir: aggregate, minimumIOS: minOS, sdk: ctx.sdk, env: swiftEnv)
            let required = try SwiftPackages.requiredSymbols(cargoTargetDir: cargoOut, crateLib: crate.lib, nm: nm)
            try SwiftPackages.checkGlobalSymbols(archive: swiftLib, required: required, nm: nm)

            // 6. The target's own sources.
            let objDir = try Files.fresh(work.appendingPathComponent(".xless/obj", isDirectory: true))
            let headers = NativeLink.expandSettings(NativeLink.setting("HEADER_SEARCH_PATHS", in: r.target.settings) ?? "", vars: vars)
            var objects: [String] = []
            for source in nativeSources(r.target.sources, appleDir: apple) {
                let rel = String(source.path.dropFirst(apple.path.count + 1))
                let object = objDir.appendingPathComponent(rel + ".o")
                try fm.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
                log("clang \(rel)")
                try run(["clang"] + NativeLink.compileArguments(source: source.path, object: object.path, headerSearchPaths: headers, minOS: minOS, sdk: sdkRoot),
                        cwd: apple, env: ctx.tools, ctx: ctx, stage: .build)
                objects.append(object.path)
            }

            // 7. Link. ld64.lld warns that it "does not support linking for platform iOS" once per input; the output is
            // captured, and on failure the error shows the other lines.
            let deps = try NativeLink.dependencyInputs(target: r.target, overlay: ctx.overlay, workRoot: work, appleDir: r.appleDir)
            let linkDir = work.appendingPathComponent(".xless/link", isDirectory: true)
            try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
            let executable = linkDir.appendingPathComponent(ios.product)
            let inputs = NativeLink.LinkInputs(
                objects: objects, libraryPaths: searchPaths, libraries: [crate.lib] + deps.libraries,
                archives: [swiftLib.path], frameworkPaths: deps.frameworkPaths, frameworks: deps.frameworks, linkFlags: deps.linkFlags,
                sdkFrameworks: deps.sdkFrameworks, clangRuntime: try ctx.sdk.clangRuntime(platform: "ios").path,
                swiftLibPaths: [sdkRoot.appendingPathComponent("usr/lib/swift").path, ctx.sdk.toolchain.appendingPathComponent("usr/lib/swift/iphoneos").path],
                minOS: minOS, sdk: sdkRoot, ld64: ctx.sdk.ld64, output: executable.path)
            log("clang++ → \(ios.product)")
            try Shell.run("clang++", NativeLink.linkArguments(inputs), cwd: apple, env: ctx.tools, baseEnvironment: ctx.env, stage: .build,
                          keepErrorLine: { !$0.contains("does not support linking for platform iOS") })

            // 8. The bundle.
            return try Files.atomicOutput(ctx.paths.app) { try AppAssembler.assemble(resolved: r, workRoot: work, executable: executable, into: $0, note: { log($0) }) }
        }
    }

    /// The build-setting variables of a release device build of the target in the work copy.
    static func settingsVariables(resolved r: ResolvedTauri, workRoot: URL, sdk: DarwinSDK) throws -> [String: String] {
        let apple = workRoot.appendingPathComponent(r.appleDir).path
        var vars = r.target.settings
        for (k, v) in [
            "PROJECT_DIR": apple, "SRCROOT": apple, "SOURCE_ROOT": apple, "PROJECT_NAME": r.projectName, "TARGET_NAME": r.target.name,
            "CONFIGURATION": "release", "SDKROOT": try sdk.sdkPath("iphoneos").path, "PLATFORM_NAME": "iphoneos",
            "EFFECTIVE_PLATFORM_NAME": "-iphoneos", "DEVELOPER_DIR": sdk.bundle.appendingPathComponent("Developer").path,
            "TOOLCHAIN_DIR": sdk.toolchain.path, "ARCHS": "arm64", "CURRENT_ARCH": "arm64",
            "PRODUCT_NAME": try r.config.platform(.ios).product,
        ] { vars[k] = v }
        return vars
    }

    /// `.m`/`.mm`/`.c`/`.cc`/`.cpp`/`.cxx` files of the target's sources, in source order (files of a directory sorted),
    /// skipping resources, folder references and `buildPhase: none`.
    static func nativeSources(_ sources: [XcodeGenTarget.Source], appleDir: URL) -> [URL] {
        let exts: Set<String> = ["m", "mm", "c", "cc", "cpp", "cxx"]
        var out: [URL] = []
        for s in sources where s.type != "folder" && !["resources", "none"].contains(s.buildPhase ?? "") {
            let url = appleDir.appendingPathComponent(s.path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let files = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String]) ?? []
                out += files.filter { exts.contains(($0 as NSString).pathExtension) }.sorted().map { url.appendingPathComponent($0) }
            } else if exts.contains(url.pathExtension) {
                out.append(url)
            }
        }
        return out
    }

    static func beforeBuildCommand(_ t: TauriConfig) -> (script: String, cwd: String?)? {
        switch (t.raw["build"] as? [String: Any])?["beforeBuildCommand"] {
        case let s as String: s.isEmpty ? nil : (s, nil)
        case let d as [String: Any]: (d["script"] as? String).map { ($0, d["cwd"] as? String) }
        default: nil
        }
    }

    /// The package of `manifest` in `cargo metadata`: its name, its library's file name stem and the target directory.
    static func rootCrate(metadata: Data, manifest: URL) throws -> (package: String, lib: String, targetDir: URL) {
        struct Metadata: Decodable {
            struct Package: Decodable {
                struct Target: Decodable { var name: String; var kind: [String] }
                var name: String; var manifest_path: String; var targets: [Target]
            }
            var packages: [Package]; var target_directory: String
        }
        let m: Metadata
        do { m = try JSONDecoder().decode(Metadata.self, from: metadata) } catch {
            throw XlessError(.build, "cannot read cargo metadata: \(error)", fix: "run `cargo metadata --format-version 1` in the Tauri directory to see what fails")
        }
        let want = manifest.resolvingSymlinksInPath().standardizedFileURL.path
        guard let pkg = m.packages.first(where: { URL(fileURLWithPath: $0.manifest_path).resolvingSymlinksInPath().standardizedFileURL.path == want }) else {
            throw XlessError(.build, "cargo metadata has no package for \(manifest.path)", fix: "point tauri.dir in the overlay at the app crate's directory")
        }
        guard let lib = pkg.targets.first(where: { !Set($0.kind).isDisjoint(with: ["lib", "staticlib", "cdylib", "rlib"]) }) else {
            throw XlessError(.build, "crate \(pkg.name) has no [lib] target", fix: "Tauri mobile apps need a [lib] with crate-type [\"staticlib\", \"cdylib\", \"rlib\"] (see `tauri ios init`)")
        }
        return (pkg.name, lib.name.replacingOccurrences(of: "-", with: "_"), URL(fileURLWithPath: m.target_directory, isDirectory: true))
    }

    /// rustup's `llvm-nm`/`llvm-objdump` for the app's toolchain. Never the image's LLVM 14 tools on PATH, which cannot
    /// read the bitcode in a Rust staticlib (contract doc, "SwiftRs").
    static func rustLLVMTool(_ name: String, _ ctx: TauriBuildContext) throws -> String {
        let tool = SwiftPackages.llvmTool(name, cwd: ctx.tauriDir, env: ctx.tools)
        guard tool.contains("/") else {
            throw XlessError(.build, "rustup's \(name) (component llvm-tools) is not installed for the app's Rust toolchain",
                             fix: "rustup component add llvm-tools (in \(ctx.resolved.tauriDir)); `xless prepare` does this")
        }
        return tool
    }

    private static func run(_ argv: [String], cwd: URL?, env: [String: String?], ctx: TauriBuildContext, stage: Stage) throws {
        try Shell.run(argv[0], Array(argv.dropFirst()), cwd: cwd, env: env, baseEnvironment: ctx.env, stage: stage, passthrough: true)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("xless: \(message)\n".utf8))
    }
}
