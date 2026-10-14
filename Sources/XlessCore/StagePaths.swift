import Foundation

public struct StagePaths: Sendable {
    public let root: URL

    public init(project: URL, platform: Platform) {
        root = project.appendingPathComponent(".xless/build/\(platform.rawValue)", isDirectory: true)
    }

    public var app: URL { root.appendingPathComponent("app", isDirectory: true) }
    public var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var final: URL { root.appendingPathComponent("final", isDirectory: true) }
    public var signed: URL { root.appendingPathComponent("signed", isDirectory: true) }
    public var out: URL { root.appendingPathComponent("out", isDirectory: true) }
    public var uploadRecord: URL { root.appendingPathComponent("upload.json") }

    /// The single `.app` inside a stage directory.
    public func bundle(in dir: URL, stage: Stage) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw XlessError(stage, "no .app found in \(dir.path)", fix: "run the previous stage first (or `xless ship`)")
        }
        return app
    }
}
