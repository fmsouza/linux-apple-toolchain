import XlessCore

/// Adds the keys Xcode stamps into every built product's Info.plist.
public enum InfoPlistStamper {
    public static func stamp(_ p: inout [String: Any], meta: ToolchainMeta, sdk: PlatformSDKInfo,
                             platform: Platform, config: ProjectConfig) throws {
        let pc = try config.platform(platform)
        p["DTPlatformName"] = sdk.platformName
        p["DTPlatformVersion"] = sdk.platformVersion
        p["DTPlatformBuild"] = sdk.platformBuild
        p["DTSDKName"] = sdk.sdkName
        p["DTSDKBuild"] = sdk.sdkBuild
        p["DTXcode"] = meta.xcodeVersion
        p["DTXcodeBuild"] = meta.xcodeBuild
        p["DTCompiler"] = meta.compiler
        p["BuildMachineOSBuild"] = meta.buildMachineOSBuild
        p["CFBundleShortVersionString"] = config.version
        p["CFBundleVersion"] = config.build
        p["CFBundleSupportedPlatforms"] = [platform.supportedPlatformName]
        switch platform {
        case .ios:
            p["MinimumOSVersion"] = pc.minimumOS
            if p["CFBundleIcons"] != nil { p.removeValue(forKey: "CFBundleIconFile") }
        case .macos:
            p["LSMinimumSystemVersion"] = pc.minimumOS
        }
    }
}
