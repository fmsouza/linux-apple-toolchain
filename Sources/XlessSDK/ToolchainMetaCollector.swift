import Foundation
import XlessCore

public enum ToolchainMetaCollector {
    /// "27.0" → "2700", "16.4" → "1640", "26.0.1" → "2601" (Xcode's DTXcode encoding).
    public static func xcodeVersionCode(_ shortVersion: String) throws -> String {
        guard let v = DottedVersion(shortVersion), v.parts[1] < 10, v.parts[2] < 10 else {
            throw XlessError(.sdk, "unexpected Xcode version '\(shortVersion)'", fix: "check Xcode.app/Contents/version.plist")
        }
        return String(format: "%02d%d%d", v.parts[0], v.parts[1], v.parts[2])
    }

    public static func collect(xcodeApp: URL, buildMachineOSBuild: String) throws -> ToolchainMeta {
        let version = try Plist.read(xcodeApp.appendingPathComponent("Contents/version.plist"), stage: .sdk)
        guard let short = version["CFBundleShortVersionString"] as? String,
              let build = version["ProductBuildVersion"] as? String else {
            throw XlessError(.sdk, "Xcode version.plist lacks version keys", fix: "pass the path to a full Xcode.app")
        }
        var platforms: [String: PlatformSDKInfo] = [:]
        for (p, dirName) in [(Platform.ios, "iPhoneOS"), (Platform.macos, "MacOSX")] {
            let platformDir = xcodeApp.appendingPathComponent("Contents/Developer/Platforms/\(dirName).platform")
            let sdkDir = platformDir.appendingPathComponent("Developer/SDKs/\(dirName).sdk")
            let settingsURL = sdkDir.appendingPathComponent("SDKSettings.json")
            guard let data = try? Data(contentsOf: settingsURL),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let canonical = settings["CanonicalName"] as? String,
                  let sdkVersion = settings["Version"] as? String else {
                throw XlessError(.sdk, "cannot read \(settingsURL.path)", fix: "pass the path to a full Xcode.app with the \(dirName) platform installed")
            }
            let sysVersion = try Plist.read(sdkDir.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"), stage: .sdk)
            guard let sdkBuild = sysVersion["ProductBuildVersion"] as? String else {
                throw XlessError(.sdk, "\(dirName).sdk SystemVersion.plist lacks ProductBuildVersion", fix: "reinstall the \(dirName) platform in Xcode")
            }
            let platformInfo = (try? Plist.read(platformDir.appendingPathComponent("Info.plist"), stage: .sdk)) ?? [:]
            platforms[p.sdkKey] = PlatformSDKInfo(
                sdkName: canonical, sdkVersion: sdkVersion, sdkBuild: sdkBuild,
                platformName: p.sdkKey,
                platformVersion: platformInfo["DTPlatformVersion"] as? String ?? sdkVersion,
                platformBuild: platformInfo["DTPlatformBuild"] as? String ?? sdkBuild)
        }
        return ToolchainMeta(xcodeVersion: try xcodeVersionCode(short), xcodeBuild: build,
                             buildMachineOSBuild: buildMachineOSBuild, compiler: ToolchainMeta.clangCompiler,
                             platforms: platforms)
    }
}
