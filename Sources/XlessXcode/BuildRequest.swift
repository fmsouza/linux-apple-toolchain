import Foundation
import XlessCore

/// The `swbuild build --buildRequestFile` JSON (an `SWBBuildRequest`) for a scheme's build action. It replaces the
/// CLI's own request, whose `useImplicitDependencies` is false: React Native app targets declare no target
/// dependencies and are ordered by implicit dependencies only (contract doc, "Implicit dependencies"). Every key is
/// present because the type decodes with synthesized `Codable`.
public enum BuildRequest {
    public enum Destination: String, Sendable {
        /// `generic/platform=iOS`: device SDK, arm64 only.
        case iphoneos
        /// The iOS Simulator SDK, arm64 only (an Apple-silicon Mac's simulator; `generic/platform=iOS Simulator` would
        /// also build x86_64).
        case iphonesimulator

        /// `PLATFORM_NAME` / the SDK name, as in `Products/<configuration>-<platformName>`.
        public var platformName: String { rawValue }
    }

    public static func make(workspace: Workspace, scheme: Scheme, configuration: String, overrides: [String: String],
                            action: SchemeAction = .running, destination: Destination = .iphoneos) throws -> Data {
        let targets = try workspace.buildTargets(of: scheme, for: action)
        let request = JSON.object([
            "parameters": .object([
                "action": .string("build"),
                "configurationName": .string(configuration),
                "activeRunDestination": runDestination(destination),
                "overrides": .object(["commandLine": .object(["table": .object(overrides.mapValues(JSON.string))])]),
            ]),
            "configuredTargets": .array(targets.map {
                .object(["guid": .string(PIFWriter.targetGUID($0.target, in: $0.project, workspace: workspace))])
            }),
            "useImplicitDependencies": .bool(scheme.buildImplicitDependencies),
            "dependencyScope": .string("workspace"),
            "useParallelTargets": .bool(scheme.parallelizeBuildables),
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

    /// The request's `activeRunDestination`: the destination's platform and SDK, arm64 only.
    public static func runDestination(_ destination: Destination) -> JSON {
        .object([
            "platform": .string(destination.platformName), "sdk": .string(destination.platformName),
            "targetArchitecture": .string("arm64"), "supportedArchitectures": .array([.string("arm64")]),
            "disableOnlyActiveArch": .bool(true),
        ])
    }
}
