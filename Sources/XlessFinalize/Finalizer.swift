import Foundation
import XlessCore
import XlessMachO

public enum Finalizer {
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, meta: ToolchainMeta) throws -> URL {
        try Files.atomicOutput(outputDir) { partial in
            let pc = try config.platform(platform)
            let sdk = try meta.sdk(for: platform)
            try Requirements.checkSDK(sdk, platform: platform)
            try Requirements.checkDeployment(pc.minimumOS, platform: platform)
            return try finalize(Files.copyBundle(input, intoFreshDir: partial), pc: pc, sdk: sdk, platform: platform, config: config, meta: meta)
        }
    }

    static func finalize(_ app: URL, pc: PlatformConfig, sdk: PlatformSDKInfo, platform: Platform, config: ProjectConfig, meta: ToolchainMeta) throws -> URL {
        let layout = BundleLayout(platform: platform)

        let plistURL = app.appendingPathComponent(layout.infoPlist)
        var info = try Plist.read(plistURL, stage: .finalize)
        try InfoPlistStamper.stamp(&info, meta: meta, sdk: sdk, platform: platform, config: config)
        if platform == .ios, config.distribution(for: .ios) == .appStore, info[InfoPlistStamper.encryptionKey] == nil {
            throw XlessError(.finalize, "Info.plist has no ITSAppUsesNonExemptEncryption (export compliance); every upload would stall at \"Missing Compliance\" in TestFlight",
                             fix: "add `usesNonExemptEncryption: false` to xless.yml (true if the app uses non-exempt encryption), or add ITSAppUsesNonExemptEncryption to the file named by `infoPlist`")
        }
        if platform == .ios, config.distribution(for: .ios) == .appStore, let v = info[InfoPlistStamper.encryptionKey], !(v is Bool) {
            throw XlessError(.finalize, "ITSAppUsesNonExemptEncryption in the Info.plist is not a boolean (\(v))",
                             fix: "make it <true/> or <false/> in the file named by `infoPlist`, or remove it and set `usesNonExemptEncryption` in xless.yml")
        }
        try Plist.write(info, to: plistURL, stage: .finalize)
        let pkgInfo = app.appendingPathComponent(layout.pkgInfo)
        if !FileManager.default.fileExists(atPath: pkgInfo.path) {
            try Data("APPL????".utf8).write(to: pkgInfo)   // Xcode writes it for every app; xtool omits it on iOS
        }

        let frameworks = app.appendingPathComponent(layout.frameworksDir).standardizedFileURL.path
        let exeName = info["CFBundleExecutable"] as? String ?? pc.product
        let mainExe = (layout.executableDir.isEmpty ? app.appendingPathComponent(exeName) : app.appendingPathComponent("\(layout.executableDir)/\(exeName)"))
            .standardizedFileURL.path
        let sdkValue = try MachO.encodeVersion(sdk.sdkVersion)
        let wantedMinOS = try MachO.encodeVersion(pc.minimumOS)
        var sawMain = false

        for file in Files.regularFiles(under: app) {
            let path = file.standardizedFileURL.path
            let rel = String(path.dropFirst(app.standardizedFileURL.path.count + 1))
            if file.pathExtension == "dylib", file.deletingLastPathComponent().standardizedFileURL.path == frameworks {
                throw XlessError(.finalize, "loose dynamic library \(rel) in the bundle (App Store rejects these)",
                                 fix: "make the library static (remove `type: .dynamic`) — dylib→framework wrapping is not supported in milestone 1")
            }
            var data: Data
            do { data = try Data(contentsOf: file) } catch {
                throw XlessError(.finalize, "cannot read \(rel): \(error)", fix: "check file permissions and disk state")
            }
            let isImage: Bool
            do { isImage = try MachO.containsLoadableImage(data) } catch {
                throw XlessError(.finalize, "cannot parse Mach-O \(rel): \(error)", fix: "report this binary to the xless maintainers")
            }
            guard isImage else { continue }   // static archives (also fat-wrapped) carry no LC_BUILD_VERSION
            let versions: [BuildVersion]
            do { versions = try MachO.buildVersions(in: data) } catch {
                throw XlessError(.finalize, "cannot parse Mach-O \(rel): \(error)", fix: "report this binary to the xless maintainers")
            }
            if versions.isEmpty {
                throw XlessError(.finalize, "\(rel) has no LC_BUILD_VERSION (legacy or malformed Mach-O); its SDK version cannot be patched",
                                 fix: "rebuild the dependency that ships \(rel) with a modern toolchain so it carries LC_BUILD_VERSION")
            }
            for v in versions where v.platform != platform.machOPlatform {
                throw XlessError(.finalize, "\(rel) was built for Mach-O platform \(v.platform), expected \(platform.machOPlatform) (\(platform.rawValue))",
                                 fix: "remove prebuilt binaries for other platforms from the package")
            }
            if path == mainExe {
                sawMain = true
                for v in versions where v.minos != wantedMinOS {
                    throw XlessError(.finalize, "binary deployment target \(MachO.decodeVersion(v.minos)) ≠ xless.yml minimumOS \(pc.minimumOS)",
                                     fix: "make Package.swift platforms (.\(platform == .ios ? "iOS" : "macOS")(\"\(pc.minimumOS)\")) match platforms.\(platform.rawValue).minimumOS")
                }
            }
            try MachO.patchSDK(in: &data, to: sdkValue)
            try data.write(to: file)
        }
        if !sawMain {
            throw XlessError(.finalize, "main executable not found at \(mainExe)", fix: "check CFBundleExecutable and the build output")
        }

        let privacy = app.appendingPathComponent(layout.resourcesDir.isEmpty ? "PrivacyInfo.xcprivacy" : "\(layout.resourcesDir)/PrivacyInfo.xcprivacy")
        if config.distribution(for: platform) == .appStore, config.privacyManifest == nil || !FileManager.default.fileExists(atPath: privacy.path) {
            throw XlessError(.finalize, "no PrivacyInfo.xcprivacy in the bundle (required for App Store uploads)",
                             fix: "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` to xless.yml (or to the Tauri overlay)")
        }
        return app
    }
}
