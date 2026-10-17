import Foundation
import XlessCore
import XlessMachO

/// Puts the linked executable into `<Product>.app` the way Xcode's build of the Tauri target does: Info.plist, folder
/// references (with bundle.resources staged into `assets/` first, as tauri-cli does) and embedded frameworks. The asset catalog and launch storyboard are compiled later by the `assets`
/// stage; DT* keys and the SDK version by `finalize`.
public enum AppAssembler {
    public static func assemble(resolved: ResolvedTauri, workRoot: URL, executable: URL, into appDir: URL,
                                 note: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let product = try resolved.config.platform(.ios).product
        let apple = workRoot.appendingPathComponent(resolved.appleDir)
        let app = appDir.appendingPathComponent("\(product).app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)

        let exe = app.appendingPathComponent(product)
        try fm.copyItem(at: executable, to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try Plist.write(try infoPlist(resolved: resolved, workRoot: workRoot), to: app.appendingPathComponent("Info.plist"), stage: .build)
        try Data("APPL????".utf8).write(to: app.appendingPathComponent("PkgInfo"))
        if let privacy = resolved.config.privacyManifest {
            // The overlay's path is absolute (resolved against the overlay file); a relative one is in the work copy.
            let src = privacy.hasPrefix("/") ? URL(fileURLWithPath: privacy) : workRoot.appendingPathComponent(privacy)
            guard fm.fileExists(atPath: src.path) else {
                throw XlessError(.build, "privacyManifest \(src.path) does not exist", fix: "fix privacyManifest in the overlay (a relative path resolves against the overlay file's directory)")
            }
            try fm.copyItem(at: src, to: app.appendingPathComponent("PrivacyInfo.xcprivacy"))
        }

        // bundle.resources, staged into gen/apple/assets/ with Tauri's path mapping, as `tauri ios build` does (shipped
        // through the `assets` folder reference; the Mac reference has assets/resources/hello.txt).
        let tauriDir = workRoot.appendingPathComponent(resolved.tauriDir)
        let resources = try TauriMacBundler.resourceMappings(resources: (resolved.tauri.raw["bundle"] as? [String: Any])?["resources"], tauriDir: tauriDir)
        try stageResources(resources, resolved: resolved, workRoot: workRoot)

        // Folder references are copied as folders. tauri-build creates `assets/` (empty for an app without bundle
        // resources; the Mac reference ships it empty), so a missing one becomes an empty folder too.
        for s in resolved.target.sources where s.type == "folder" && s.buildPhase != "none" {
            let src = apple.appendingPathComponent(s.path), dst = app.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) } else { try fm.createDirectory(at: dst, withIntermediateDirectories: true) }
        }

        // Embedded frameworks: the device slice only, without Headers/Modules (Xcode's REMOVE_HEADERS_FROM_EMBEDDED_BUNDLES).
        for case .framework(let path, true, _) in resolved.target.dependencies {
            let url = apple.appendingPathComponent(path)
            let framework: URL
            switch url.pathExtension {
            case "xcframework":
                guard let slice = deviceSlice(of: url) else {
                    throw XlessError(.build, "\(path) has no iOS device slice", fix: "check that the xcframework (installed by binaryDependencies?) contains an ios-arm64 library")
                }
                framework = slice.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).framework")
            case "framework": framework = url
            default: continue
            }
            guard fm.fileExists(atPath: framework.path) else {
                throw XlessError(.build, "embedded framework \(framework.path) does not exist", fix: "check the project.yml dependency \(path) and the overlay's binaryDependencies")
            }
            // A framework whose binary is a static archive is linked into the executable; an embedded copy would never be
            // loaded, and rcodesign cannot sign it.
            let binary = framework.appendingPathComponent(framework.deletingPathExtension().lastPathComponent)
            let isImage: Bool
            do { isImage = try MachO.containsLoadableImage(try Data(contentsOf: binary)) } catch {
                throw XlessError(.build, "cannot read framework binary \(binary.path): \(error)", fix: "check the project.yml dependency \(path) and the overlay's binaryDependencies")
            }
            if !isImage {
                note("note: \(framework.lastPathComponent) is a static library; linked, not embedded")
                continue
            }
            let dest = app.appendingPathComponent("Frameworks/\(framework.lastPathComponent)", isDirectory: true)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: framework, to: dest)
            for strip in ["Headers", "PrivateHeaders", "Modules"] { try? fm.removeItem(at: dest.appendingPathComponent(strip)) }
        }
        return app
    }

    /// The work-copy-relative record of the files xless copied into `gen/apple/assets/` (one path per line, relative to
    /// `assets/`).
    static let resourcesManifest = ".xless/ios-resources.txt"

    /// Copies `resources` into `<appleDir>/assets/<target>`. The files a previous build copied (`resourcesManifest`) are
    /// removed first, so a resource dropped from bundle.resources does not ship; a file the app's repository tracks
    /// (`.xless/tracked.txt`) is never removed.
    static func stageResources(_ resources: [TauriMacBundler.Resource], resolved: ResolvedTauri, workRoot: URL) throws {
        let fm = FileManager.default
        let assets = workRoot.appendingPathComponent("\(resolved.appleDir)/assets", isDirectory: true)
        let manifest = workRoot.appendingPathComponent(resourcesManifest)
        let tracked = Set((try? String(contentsOf: workRoot.appendingPathComponent(".xless/tracked.txt"), encoding: .utf8))?
            .split(separator: "\0").map(String.init) ?? [])
        let previous = (try? String(contentsOf: manifest, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        for target in previous where !target.split(separator: "/").contains("..") && !tracked.contains("\(resolved.appleDir)/assets/\(target)") {
            var url = assets.appendingPathComponent(target)
            try? fm.removeItem(at: url)
            // Directories left empty by the removal go too, up to (not including) assets/.
            url = url.deletingLastPathComponent()
            while url.standardizedFileURL.path.count > assets.standardizedFileURL.path.count,
                  (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fm.removeItem(at: url)
                url = url.deletingLastPathComponent()
            }
        }
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Recorded before copying, so a copy that fails part-way is still cleaned up by the next build.
        try resources.map { "\($0.target)\n" }.joined().write(to: manifest, atomically: true, encoding: .utf8)
        for res in resources {
            let dst = assets.appendingPathComponent(res.target)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: res.source.resolvingSymlinksInPath(), to: dst)
        }
    }

    /// `info.path` (or the overlay's `infoPlist`), with `<tauriDir>/Info.ios.plist` dict-merged over it (as tauri-cli
    /// does), then `info.properties`; `$(VAR)` placeholders expanded; then the bundle identity and the keys Xcode's build
    /// adds from build settings (MinimumOSVersion, CFBundleSupportedPlatforms, UIDeviceFamily).
    static func infoPlist(resolved: ResolvedTauri, workRoot: URL) throws -> [String: Any] {
        let config = resolved.config, ios = try config.platform(.ios)
        guard let infoPath = config.infoPlist else {
            throw XlessError(.build, "no Info.plist for the app target", fix: "set info.path in project.yml or infoPlist in the overlay")
        }
        var info = try Plist.read(workRoot.appendingPathComponent(infoPath), stage: .build)
        let iosPlist = workRoot.appendingPathComponent("\(resolved.tauriDir)/Info.ios.plist")
        if FileManager.default.fileExists(atPath: iosPlist.path) { info = deepMerge(info, try Plist.read(iosPlist, stage: .build)) }
        // bundle.fileAssociations → CFBundleDocumentTypes (and UTExportedTypeDeclarations), as tauri-cli writes them into
        // the target's Info.plist.
        for (k, v) in try TauriMacBundler.fileAssociationsPlist((resolved.tauri.raw["bundle"] as? [String: Any])?["fileAssociations"]) { info[k] = v }
        for (k, v) in resolved.target.infoProperties { info[k] = v }

        var vars = resolved.target.settings
        vars["PRODUCT_NAME"] = ios.product
        vars["EXECUTABLE_NAME"] = ios.product
        vars["PRODUCT_MODULE_NAME"] = ios.product.replacing(/[^A-Za-z0-9_]/, with: "_")
        vars["PRODUCT_BUNDLE_IDENTIFIER"] = try config.bundleID(for: .ios)
        vars["DEVELOPMENT_LANGUAGE"] = vars["DEVELOPMENT_LANGUAGE"] ?? "en"
        info = expand(info, vars: vars) as? [String: Any] ?? info

        info["CFBundleIdentifier"] = try config.bundleID(for: .ios)
        info["CFBundleExecutable"] = ios.product
        info["CFBundleShortVersionString"] = config.version
        info["CFBundleVersion"] = config.build
        info["CFBundlePackageType"] = "APPL"
        info["MinimumOSVersion"] = ios.minimumOS
        info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        if info["UIDeviceFamily"] == nil {
            let family = (NativeLink.setting("TARGETED_DEVICE_FAMILY", in: resolved.target.settings) ?? "1,2")
                .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            info["UIDeviceFamily"] = family
        }
        return info
    }

    /// Dictionary-deep merge; `overlay` wins for everything that is not a dictionary on both sides.
    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in overlay {
            if let b = out[k] as? [String: Any], let o = v as? [String: Any] { out[k] = deepMerge(b, o) } else { out[k] = v }
        }
        return out
    }

    private static func expand(_ value: Any, vars: [String: String]) -> Any {
        switch value {
        case let s as String: s.replacing(/\$[({]([A-Za-z0-9_]+)[)}]/) { vars[String($0.1)] ?? "" }
        case let d as [String: Any]: d.mapValues { expand($0, vars: vars) }
        case let a as [Any]: a.map { expand($0, vars: vars) }
        default: value
        }
    }

    /// The iOS device library of an xcframework: from its Info.plist (`SupportedPlatform` ios, no variant), else `ios-arm64`.
    public static func deviceSlice(of xcframework: URL) -> URL? {
        let fm = FileManager.default
        if let info = try? Plist.read(xcframework.appendingPathComponent("Info.plist"), stage: .build),
           let libs = info["AvailableLibraries"] as? [[String: Any]],
           let id = libs.first(where: { $0["SupportedPlatform"] as? String == "ios" && $0["SupportedPlatformVariant"] == nil })?["LibraryIdentifier"] as? String,
           fm.fileExists(atPath: xcframework.appendingPathComponent(id).path) {
            return xcframework.appendingPathComponent(id, isDirectory: true)
        }
        let fallback = xcframework.appendingPathComponent("ios-arm64", isDirectory: true)
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
