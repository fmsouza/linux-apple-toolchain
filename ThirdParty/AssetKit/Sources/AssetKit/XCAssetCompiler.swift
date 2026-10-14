import Foundation

public struct CompileResult: Sendable {
    /// The compiled `Assets.car` bytes. Always present, even if the catalog
    /// contained no assets (callers receive a structurally valid empty CAR).
    public var carData: Data

    /// Glue needed to ship an `.appiconset` as part of an iOS app bundle.
    /// `nil` if the catalog contained no `.appiconset`. Present iff the
    /// catalog contained exactly one `.appiconset`.
    public var appIconBundle: AppIconBundle?

    public init(carData: Data, appIconBundle: AppIconBundle? = nil) {
        self.carData = carData
        self.appIconBundle = appIconBundle
    }
}

/// iOS-app-bundle glue derived from the catalog's `.appiconset`. The .car
/// alone is not enough to ship an iOS app icon: SpringBoard's icon-render
/// pipeline falls back to a set of loose PNGs in the bundle root, and the
/// `Info.plist` must declare them.
public struct AppIconBundle: Sendable {
    /// The basename of the `.appiconset` (e.g. "AppIcon"), used as the
    /// `CFBundleIconName` value.
    public var primaryIconName: String

    /// Plist keys to merge into the app's `Info.plist`. Includes
    /// `CFBundleIconName`, `CFBundleIcons`, `CFBundleIcons~ipad`, and the
    /// flat `CFBundleIconFiles` fallback list.
    public var infoPlistAdditions: [String: any Sendable]

    /// Loose PNG files that must be copied into the app bundle root
    /// alongside `Assets.car`, named per `CFBundleIconFiles` entries (e.g.
    /// `AppIcon60x60@2x.png`). SpringBoard's icon-rendering pipeline reads
    /// these directly when CoreUI's rendition lookup misses (which happens
    /// when our CRC32-derived NameIdentifier differs from actool's hash) --
    /// without these files, home-screen icons fail to render.
    public var looseFiles: [LooseFile]

    public init(
        primaryIconName: String,
        infoPlistAdditions: [String: any Sendable],
        looseFiles: [LooseFile]
    ) {
        self.primaryIconName = primaryIconName
        self.infoPlistAdditions = infoPlistAdditions
        self.looseFiles = looseFiles
    }
}

public struct LooseFile: Sendable {
    /// Filename relative to the app bundle root (e.g. "AppIcon60x60@2x.png").
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct XCAssetCompiler: Sendable {
    public var deploymentTarget: String
    /// Strategy used to rasterise `.svg` sources to PNG bytes. Defaults to
    /// `RsvgConvertRasterizer`, which shells out to `rsvg-convert`. Replace
    /// when you need a different rasteriser (no PATH dep, different
    /// performance profile, sandbox restrictions, etc).
    public var svgRasterizer: any SVGRasterizer

    public init(
        deploymentTarget: String,
        svgRasterizer: any SVGRasterizer = RsvgConvertRasterizer()
    ) {
        self.deploymentTarget = deploymentTarget
        self.svgRasterizer = svgRasterizer
    }

    public func compile(catalog catalogURL: URL) async throws -> CompileResult {
        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: catalogURL)

        var renditions: [Rendition] = []

        for imageSet in loaded.imageSets {
            renditions.append(contentsOf: try ImageRenderer.renditions(
                for: imageSet,
                svgRasterizer: svgRasterizer
            ))
        }
        for colorSet in loaded.colorSets {
            renditions.append(contentsOf: try ColorRenderer.renditions(for: colorSet))
        }

        var appIconBundle: AppIconBundle?
        if let appIcon = loaded.appIcon {
            let plist = try AppIconPlistEmitter.emit(appIcon)
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(for: appIcon, files: plist.iconFiles))

            var looseFiles: [LooseFile] = []
            for file in plist.iconFiles {
                let suffix = file.scale == 1 ? "" : "@\(file.scale)x"
                let target = "\(file.outputName)\(suffix).png"
                let data = try Data(contentsOf: file.sourceURL)
                looseFiles.append(LooseFile(name: target, data: data))
            }

            appIconBundle = AppIconBundle(
                primaryIconName: plist.iconName,
                infoPlistAdditions: plist.infoPlistAdditions,
                looseFiles: looseFiles
            )
        }

        let writer = CARWriter(deploymentTarget: deploymentTarget, renditions: renditions)
        let bytes = try writer.write()

        return CompileResult(carData: bytes, appIconBundle: appIconBundle)
    }
}
