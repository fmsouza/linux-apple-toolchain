import AssetKit
import Foundation
import XlessCore
import XlessIB
import XlessMachO

public enum AssetsStage {
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL) async throws -> URL {
        try await Files.atomicOutput(outputDir) { partial in
            try await compile(into: Files.copyBundle(input, intoFreshDir: partial), platform: platform, config: config, project: project)
        }
    }

    static func compile(into app: URL, platform: Platform, config: ProjectConfig, project: URL) async throws -> URL {
        if config.distribution(for: platform) == .appStore,
           config.assets.map({ appIconSet(catalog: project.appendingPathComponent($0)) == nil }) ?? true {
            // App Store Connect rejects icon-less builds only after a full upload (ITMS-90022/90704).
            let missing = config.assets.map { "\($0) has no .appiconset" } ?? "xless.yml has no `assets:` catalog"
            throw XlessError(.assets, "App Store builds need an app icon, but \(missing)",
                             fix: "add an AppIcon.appiconset with an opaque 1024×1024 PNG to an asset catalog and set `assets:` in xless.yml to it")
        }
        if let assets = config.assets { try await compileCatalog(assets, into: app, platform: platform, config: config, project: project) }
        if platform == .ios, let storyboard = config.launchStoryboard {
            try LaunchStoryboard.compile(project.appendingPathComponent(storyboard), into: app, minimumOS: try config.platform(.ios).minimumOS)
        }
        return app
    }

    static func compileCatalog(_ assets: String, into app: URL, platform: Platform, config: ProjectConfig, project: URL) async throws {
        let catalog = project.appendingPathComponent(assets)
        let layout = BundleLayout(platform: platform)
        let plistURL = app.appendingPathComponent(layout.infoPlist)
        var info = try Plist.read(plistURL, stage: .assets)
        let icons = try appIconPNGs(catalog: catalog)

        switch platform {
        case .ios:
            try checkIconsOpaque(icons)
            let result: CompileResult
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xless-assets-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                let copy = try normalizedCatalogCopy(catalog, in: scratch)
                result = try await XCAssetCompiler(deploymentTarget: try config.platform(.ios).minimumOS).compile(catalog: copy)
            } catch {
                throw XlessError(.assets, "AssetKit failed on \(catalog.path): \(error)", fix: "remove unsupported asset types (PDF, data sets, stickers) or report to xtool-org/AssetKit")
            }
            try result.carData.write(to: app.appendingPathComponent("Assets.car"))
            if let icon = result.appIconBundle {
                if let png = icons.first, isSingleSizeIcon(catalog: catalog) {
                    for f in try XcodeAppIcon.looseFiles(name: icon.primaryIconName, icon1024: png) {
                        try f.data.write(to: app.appendingPathComponent(f.name))
                    }
                    let family = (info["UIDeviceFamily"] as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue } ?? [1, 2]
                    for (k, v) in XcodeAppIcon.plistAdditions(name: icon.primaryIconName, deviceFamily: family) { info[k] = v }
                } else {
                    for f in icon.looseFiles { try f.data.write(to: app.appendingPathComponent(f.name)) }
                    for (k, v) in icon.infoPlistAdditions { info[k] = v }
                }
                info.removeValue(forKey: "CFBundleIconFile")
            }
        case .macos:
            guard !icons.isEmpty else { return }
            let icns: Data
            do { icns = try ICNS.make(pngs: icons) } catch {
                throw XlessError(.assets, "cannot build AppIcon.icns: \(error)", fix: "provide square PNG app icons sized 16–1024")
            }
            try icns.write(to: app.appendingPathComponent("\(layout.resourcesDir)/AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        try Plist.write(info, to: plistURL, stage: .assets)
    }

    /// Copies the catalog into `dir`, adding the missing "scale" to app icon entries (AssetKit requires it).
    static func normalizedCatalogCopy(_ catalog: URL, in dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(catalog.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: catalog, to: copy)
        let items = (try? fm.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)) ?? []
        for set in items where set.pathExtension == "appiconset" {
            let url = set.appendingPathComponent("Contents.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            try normalizedAppIconContents(data).write(to: url)
        }
        return copy
    }

    /// Xcode's single-size app icon format omits "scale"; AssetKit needs it. Adds "1x" where missing, and files a
    /// single-size icon under the iphone and ipad idioms as actool does.
    static func normalizedAppIconContents(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var images = root["images"] as? [[String: Any]] else {
            throw XlessError(.assets, "AppIcon Contents.json is not a valid image set", fix: "re-save the asset catalog in Xcode or fix the JSON")
        }
        for i in images.indices where images[i]["scale"] == nil { images[i]["scale"] = "1x" }
        if XcodeAppIcon.isSingleSize(data), let icon = images.first(where: { $0["filename"] != nil }) {
            images = XcodeAppIcon.phoneAndPadImages(icon)
        }
        root["images"] = images
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func appIconSet(catalog: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "appiconset" }
    }

    static func isSingleSizeIcon(catalog: URL) -> Bool {
        guard let set = appIconSet(catalog: catalog) else { return false }
        return XcodeAppIcon.isSingleSize((try? Data(contentsOf: set.appendingPathComponent("Contents.json"))) ?? Data())
    }

    /// PNG files referenced by the catalog's single .appiconset.
    public static func appIconPNGs(catalog: URL) throws -> [Data] {
        guard let set = appIconSet(catalog: catalog) else { return [] }
        struct Contents: Decodable { struct Image: Decodable { var filename: String? }; var images: [Image] }
        guard let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            throw XlessError(.assets, "\(set.path)/Contents.json is missing or invalid", fix: "re-save the asset catalog in Xcode or fix the JSON")
        }
        return try contents.images.compactMap(\.filename).map { name in
            guard let d = try? Data(contentsOf: set.appendingPathComponent(name)) else {
                throw XlessError(.assets, "app icon \(name) referenced but missing", fix: "add \(set.path)/\(name)")
            }
            return d
        }
    }

    /// App Store Connect rejects iOS app icons with an alpha channel (ITMS-90717).
    public static func checkIconsOpaque(_ pngs: [Data]) throws {
        for png in pngs {
            let h: PNGHeader
            do { h = try PNGHeader.parse(png) } catch {
                throw XlessError(.assets, "an app icon is not a PNG", fix: "export app icons as PNG")
            }
            if h.hasAlpha {
                throw XlessError(.assets, "app icon \(h.width)x\(h.height) has an alpha channel (ITMS-90717)",
                                 fix: "re-export the icon without transparency (e.g. `sips -s format jpeg … | sips -s format png …` or flatten in your editor)")
            }
        }
    }
}
