public struct BundleLayout: Sendable {
    public let platform: Platform
    public init(platform: Platform) { self.platform = platform }

    public var infoPlist: String { platform == .ios ? "Info.plist" : "Contents/Info.plist" }
    public var pkgInfo: String { platform == .ios ? "PkgInfo" : "Contents/PkgInfo" }
    public var executableDir: String { platform == .ios ? "" : "Contents/MacOS" }
    public var resourcesDir: String { platform == .ios ? "" : "Contents/Resources" }
    public var frameworksDir: String { platform == .ios ? "Frameworks" : "Contents/Frameworks" }
    public var embeddedProfile: String { platform == .ios ? "embedded.mobileprovision" : "Contents/embedded.provisionprofile" }
}
