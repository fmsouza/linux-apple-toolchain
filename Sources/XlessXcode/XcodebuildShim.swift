import Foundation
import XlessCore

/// `xcodebuild` on Linux, for the calls React Native / Expo projects make (docs/research/react-native-ios-contract.md,
/// "Gate G3/G4"); anything else is refused with exit 70 and the argv (the `XcrunShim` pattern):
/// - `xcodebuild -version` (React Native's `pod install` checks the Xcode version): the SDK's Xcode version and build.
/// - `xcodebuild build -scheme <product> -sdk iphoneos -destination generic/platform=iOS -derivedDataPath <dir> …` in a
///   Swift package directory (Expo's `ExpoModulesJSI` build phase builds its package into an xcframework this way):
///   the package's PIF from SwiftPM (`dump-pif`, dynamic products as frameworks, as Xcode builds them) built by
///   `swbuild` into the same `Build/Products` / `Build/Intermediates.noindex` layout. The same phase in a simulator
///   build passes `-sdk iphonesimulator -destination "generic/platform=iOS Simulator"`: built for the simulator, arm64
///   only (Xcode's generic simulator destination also builds x86_64).
public enum XcodebuildShim {
    public enum Command: Equatable, Sendable {
        case version
        case buildPackage(PackageBuild)
    }

    public struct PackageBuild: Equatable, Sendable {
        public var scheme: String
        /// `-sdk iphoneos -destination generic/platform=iOS` or `-sdk iphonesimulator -destination "generic/platform=iOS Simulator"`.
        public var destination: BuildRequest.Destination = .iphoneos
        public var configuration: String
        public var derivedDataPath: String
        /// `NAME=VALUE` build settings from the command line, in order.
        public var settings: [Setting]
        public var quiet: Bool
        /// `-disableAutomaticPackageResolution`: SwiftPM's `--disable-automatic-resolution` for the package PIF.
        public var disableAutomaticResolution = false

        public struct Setting: Equatable, Sendable {
            public var name: String
            public var value: String
        }
    }

    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "xcodebuild shim: unsupported call (\(reason)): xcodebuild \(argv.joined(separator: " "))" }
    }

    /// Flags that change nothing for a non-interactive build: plugin and macro validation (no prompts), parallel
    /// targets (Swift Build's default).
    static let ignoredFlags: Set<String> = ["-skipPackagePluginValidation", "-skipMacroValidation", "-parallelizeTargets"]

    public static func parse(_ args: [String]) throws -> Command {
        if args == ["-version"] { return .version }
        func refuse(_ reason: String) -> Unsupported { Unsupported(argv: args, reason: reason) }
        var action: String?, scheme: String?, sdk: String?, destination: String?, derivedData: String?
        var configuration = "Debug", quiet = false, disableResolution = false
        var settings: [PackageBuild.Setting] = []
        var seen = Set<String>()
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { throw refuse("\(flag) needs a value") }
            guard seen.insert(flag).inserted else { throw refuse("\(flag) given twice") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "build": guard action == nil else { throw refuse("more than one action") }; action = a
            case "-scheme": scheme = try value(a)
            case "-sdk": sdk = try value(a)
            case "-destination": destination = try value(a)
            case "-derivedDataPath": derivedData = try value(a)
            case "-configuration": configuration = try value(a)
            case "-quiet": quiet = true
            case "-disableAutomaticPackageResolution": disableResolution = true
            case _ where ignoredFlags.contains(a): break
            default:
                guard let eq = a.firstIndex(of: "="), isSettingName(a[..<eq]) else { throw refuse("argument \(a)") }
                guard !settings.contains(where: { $0.name == a[..<eq] }) else { throw refuse("setting \(a[..<eq]) given twice") }
                settings.append(.init(name: String(a[..<eq]), value: String(a[a.index(after: eq)...])))
            }
            i += 1
        }
        guard action == "build" else { throw refuse("only the build action is supported") }
        guard let scheme else { throw refuse("no -scheme") }
        let target: BuildRequest.Destination
        switch (sdk, destination) {
        case ("iphoneos", "generic/platform=iOS"): target = .iphoneos
        case ("iphonesimulator", "generic/platform=iOS Simulator"): target = .iphonesimulator
        default:
            throw refuse("only -sdk iphoneos -destination generic/platform=iOS and -sdk iphonesimulator -destination \"generic/platform=iOS Simulator\" are supported")
        }
        guard let derivedData, derivedData.hasPrefix("/") else { throw refuse("-derivedDataPath must be an absolute path") }
        return .buildPackage(PackageBuild(scheme: scheme, destination: target, configuration: configuration, derivedDataPath: derivedData,
                                          settings: settings, quiet: quiet, disableAutomaticResolution: disableResolution))
    }

    static func isSettingName(_ s: Substring) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || ("A"..."Z").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// `xcodebuild -version`'s two lines: `Xcode 27.0` / `Build version 27A266a` (`xcodeVersion` "2700" → 27.0,
    /// "2701" → 27.0.1, "2710" → 27.1).
    public static func versionText(_ meta: ToolchainMeta) -> String {
        "Xcode \(XcodePin.xcodeVersion(meta))\nBuild version \(meta.xcodeBuild)\n"
    }

    /// SwiftPM's arguments for the package PIF: Swift Build, dynamic library products as frameworks in
    /// `PackageFrameworks` (Xcode's layout), and no `@loader_path` rpath (SwiftPM adds one for `swift run`; Xcode does not).
    public static let dumpPIFArguments = ["package", "--build-system", "swiftbuild", "--experimental-build-dylibs-as-frameworks",
                                          "--disable-local-rpath", "dump-pif"]

    /// `dumpPIFArguments` for a build: `-disableAutomaticPackageResolution` becomes SwiftPM's
    /// `--disable-automatic-resolution` (use `Package.resolved` as it is; fail rather than resolve).
    public static func dumpPIFArguments(for build: PackageBuild) -> [String] {
        build.disableAutomaticResolution
            ? Array(dumpPIFArguments.dropLast()) + ["--disable-automatic-resolution", "dump-pif"] : dumpPIFArguments
    }

    /// The build request for the package product `build.scheme`: Xcode's scheme for a package library product
    /// builds the target SwiftPM names `<product>-product`.
    public static func packageRequest(packagePIF data: Data, build: PackageBuild, overrides: [String: String]) throws -> Data {
        let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let products = objects.compactMap { o -> (guid: String, name: String)? in
            guard o["type"] as? String == "target", let c = o["contents"] as? [String: Any],
                  let guid = c["guid"] as? String, guid.hasPrefix("PACKAGE-PRODUCT:"), let name = c["name"] as? String else { return nil }
            return (guid, name)
        }
        guard let product = products.first(where: { $0.name == "\(build.scheme)-product" }) else {
            throw XlessError(.build, "the Swift package has no product named \(build.scheme) (products: \(products.map { String($0.name.dropLast("-product".count)) }.sorted().joined(separator: ", ")))",
                             fix: "build one of the package's library products")
        }
        var table = overrides
        table["SDKROOT"] = build.destination.platformName
        // The simulator's ARCHS_STANDARD is arm64 and x86_64; the build is for an Apple-silicon Mac's simulator.
        if build.destination == .iphonesimulator { table["ARCHS"] = "arm64" }
        // A command-line setting may not replace one the Linux build depends on (`SwiftBuildEnvironment.overrides`).
        if let clash = build.settings.first(where: { table[$0.name] != nil }) {
            throw Unsupported(argv: ["\(clash.name)=\(clash.value)"], reason: "\(clash.name) is set by xless for Linux builds")
        }
        for s in build.settings { table[s.name] = s.value }
        let request = JSON.object([
            "parameters": .object([
                "action": .string("build"),
                "configurationName": .string(build.configuration),
                "activeRunDestination": BuildRequest.runDestination(build.destination),
                "overrides": .object(["commandLine": .object(["table": .object(table.mapValues(JSON.string))])]),
            ]),
            "configuredTargets": .array([.object(["guid": .string(product.guid)])]),
            "useImplicitDependencies": .bool(false),
            "dependencyScope": .string("workspace"),
            "useParallelTargets": .bool(true),
            "useDryRun": .bool(false),
            "continueBuildingAfterErrors": .bool(false),
            "hideShellScriptEnvironment": .bool(true),
            "showNonLoggedProgress": .bool(true),
            "enableIndexBuildArena": .bool(false),
            "useLegacyBuildLocations": .bool(false),
            "buildCommand": .object(["command": .string("build"), "style": .string("buildOnly"), "skipDependencies": .bool(false)]),
        ])
        return Data(request.serialized(pretty: true).utf8)
    }

    /// Builds the package in `directory` (which must hold `Package.swift` and no Xcode project, as `xcodebuild` would
    /// otherwise build that). Writes the PIF, request, toolset and `swbuild` log under `<derivedData>/xless`.
    public static func buildPackage(_ build: PackageBuild, in directory: URL, environment: SwiftBuildEnvironment) throws -> SwiftBuildOutput.Summary {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            throw XlessError(.build, "xcodebuild -scheme \(build.scheme) ran in \(directory.path), which has no Package.swift",
                             fix: "only Swift package builds are supported by the xcodebuild shim")
        }
        let entries = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            throw XlessError(.build, "xcodebuild -scheme \(build.scheme) ran in \(directory.path), which has \(project): xcodebuild would build that, not the package",
                             fix: "only Swift package builds are supported by the xcodebuild shim")
        }
        let derivedData = URL(fileURLWithPath: build.derivedDataPath)
        let dir = derivedData.appendingPathComponent("xless")
        let overrides = try SwiftBuildRunner.prepareOverrides(environment, directory: dir, stage: .build)
        let pif = try Shell.run(SwiftToolchain.engineSwift(environment.swift), dumpPIFArguments(for: build), cwd: directory, stage: .build).stdout
        let request = try packageRequest(packagePIF: Data(pif.utf8), build: build, overrides: overrides)
        let pifURL = dir.appendingPathComponent("package.pif"), requestURL = dir.appendingPathComponent("request.json")
        do {
            try Data(pif.utf8).write(to: pifURL, options: .atomic)
            try request.write(to: requestURL, options: .atomic)
        } catch {
            throw XlessError(.build, "cannot write \(dir.path): \(error.localizedDescription)", fix: "check -derivedDataPath")
        }
        return try SwiftBuildRunner.build(pif: pifURL, request: requestURL, derivedData: derivedData, environment: environment,
                                          log: dir.appendingPathComponent("swbuild.log"), stage: .build)
    }
}
