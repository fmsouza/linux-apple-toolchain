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
        try stampEncryptionCompliance(&p, config: config)
        p["CFBundleSupportedPlatforms"] = [platform.supportedPlatformName]
        switch platform {
        case .ios:
            p["MinimumOSVersion"] = pc.minimumOS
            if p["CFBundleIcons"] != nil { p.removeValue(forKey: "CFBundleIconFile") }
        case .macos:
            p["LSMinimumSystemVersion"] = pc.minimumOS
        }
    }

    static let encryptionKey = "ITSAppUsesNonExemptEncryption"

    /// `usesNonExemptEncryption` in xless.yml fills the export-compliance key when the user's Info.plist lacks it; a plist value that
    /// disagrees is refused rather than silently overridden.
    static func stampEncryptionCompliance(_ p: inout [String: Any], config: ProjectConfig) throws {
        guard let wanted = config.usesNonExemptEncryption else { return }
        guard let existing = p[encryptionKey] else { p[encryptionKey] = wanted; return }
        guard let have = existing as? Bool else {
            throw XlessError(.finalize, "\(encryptionKey) in the Info.plist is not a boolean (\(existing))",
                             fix: "make it <true/> or <false/>, or remove it and let `usesNonExemptEncryption` in xless.yml set it")
        }
        if have != wanted {
            throw XlessError(.finalize, "\(encryptionKey) is \(have) in the Info.plist but `usesNonExemptEncryption` in xless.yml is \(wanted)",
                             fix: "keep one: remove the key from the infoPlist file, or make both values agree")
        }
    }
}
