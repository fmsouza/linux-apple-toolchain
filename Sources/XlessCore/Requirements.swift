/// Apple App Store Connect upload requirements.
/// Source: https://developer.apple.com/news/upcoming-requirements/ (checked 2026-10-13).
public enum Requirements {
    /// Since 2026-04-28, uploads must be built with the 26 SDKs or later.
    public static let minimumSDKMajor = 26
    /// Since 2026-09-09, iOS apps must target iOS 13 or later.
    public static let minimumIOSDeployment = "13.0"

    public static func checkSDK(_ info: PlatformSDKInfo, platform: Platform, stage: Stage = .finalize) throws {
        guard let v = DottedVersion(info.sdkVersion), v.major >= minimumSDKMajor else {
            throw XlessError(stage, "\(platform.rawValue) SDK \(info.sdkVersion) is older than Apple's minimum (\(minimumSDKMajor).0)",
                             fix: "export the SDK from Xcode \(minimumSDKMajor) or later")
        }
    }

    public static func checkDeployment(_ minimumOS: String, platform: Platform) throws {
        guard platform == .ios else { return }
        guard let v = DottedVersion(minimumOS), v >= DottedVersion(minimumIOSDeployment)! else {
            throw XlessError(.finalize, "iOS minimumOS \(minimumOS) is below Apple's minimum \(minimumIOSDeployment)",
                             fix: "raise platforms.ios.minimumOS and .iOS(...) in Package.swift")
        }
    }
}
