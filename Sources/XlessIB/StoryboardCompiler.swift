import Foundation
import XlessCore

/// The ibtool flags that affect a compiled storyboard (docs/research/ib-invocation.md).
public struct IBCompileOptions: Equatable, Sendable {
    /// `--target-device` values, sorted (`["ipad", "iphone"]` or `["iphone"]`).
    public var targetDevices: [String]
    /// `--minimum-deployment-target`, e.g. `"16.0"`.
    public var minimumDeploymentTarget: String

    public init(targetDevices: [String], minimumDeploymentTarget: String) {
        self.targetDevices = targetDevices.sorted()
        self.minimumDeploymentTarget = minimumDeploymentTarget
    }

    /// The options of a flag set in the corpus's `flagsets.json` (`{"flagsets": {name: [ibtool args]}, …}`).
    public static func flagset(named name: String, root: URL) throws -> IBCompileOptions {
        let url = root.appendingPathComponent("flagsets.json")
        let fix = "check \(url.path)"
        guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let sets = json["flagsets"] as? [String: [String]] else {
            throw XlessError(.ib, "cannot read flag sets from \(url.path)", fix: fix)
        }
        guard let args = sets[name] else { throw XlessError(.ib, "unknown flag set \(name)", fix: fix) }
        var devices: [String] = [], target: String?
        var i = 0
        while i < args.count {
            guard i + 1 < args.count else { throw XlessError(.ib, "flag set \(name): \(args[i]) has no value", fix: fix) }
            switch args[i] {
            case "--target-device": devices.append(args[i + 1])
            case "--minimum-deployment-target": target = args[i + 1]
            default: throw XlessError(.ib, "flag set \(name): unknown ibtool flag \(args[i])", fix: fix)
            }
            i += 2
        }
        guard let target else { throw XlessError(.ib, "flag set \(name) has no --minimum-deployment-target", fix: fix) }
        return IBCompileOptions(targetDevices: devices, minimumDeploymentTarget: target)
    }
}

public struct IBCompileResult: Equatable, Sendable {
    /// File contents by path relative to the `.storyboardc` directory (`Info.plist`, `X.nib`).
    public var files: [String: Data]
    /// Diagnostics ibtool would print. ibtool printed none for any corpus case, so this is empty today.
    public var warnings: [String]
}

/// Compiles a launch-screen storyboard into the files of a `.storyboardc`, byte-identical to ibtool 27.0 (27A266a).
/// Rules: docs/research/nib-encoding.md; one file per class in `Lowering/Rules`.
public enum StoryboardCompiler {
    public static func compile(url: URL, options: IBCompileOptions) throws -> IBCompileResult {
        try compile(StoryboardParser.parse(url: url), options: options)
    }

    public static func compile(_ doc: IBDocument, options: IBCompileOptions) throws -> IBCompileResult {
        try validate(options)
        try DocumentRule.check(doc)
        let scene = try SceneRule.initialScene(doc)
        let vc = scene.viewController
        let vcID = vc.id, viewID = vc.view.id
        try SceneRule.checkIdentifier(vcID, doc: doc, path: vc.rawPath)
        try SceneRule.checkIdentifier(viewID, doc: doc, path: vc.view.rawPath)

        let lowering = ViewNibLowering(doc: doc, options: options)
        let viewNib = try lowering.lower(vc.view)
        let identifier = try ViewControllerRule.storyboardIdentifier(vc, doc: doc)
        let vcNib = try ViewControllerRule.nib(vcID: vcID, viewID: viewID, storyboardIdentifier: identifier)
        return IBCompileResult(files: [
            StoryboardcLayout.infoPlistName: StoryboardcLayout.infoPlist(vcID: vcID, storyboardIdentifier: identifier),
            StoryboardcLayout.viewControllerNibName(vcID: vcID, storyboardIdentifier: identifier) + ".nib": NIBArchiveWriter.write(vcNib),
            StoryboardcLayout.viewNibName(vcID: vcID, viewID: viewID) + ".nib": NIBArchiveWriter.write(viewNib),
        ], warnings: lowering.warnings)
    }

    /// Flag sets verified against goldens: iPhone or iPhone + iPad, deployment target 15.0 or later
    /// (docs/research/nib-encoding.md, section 8).
    static func validate(_ o: IBCompileOptions) throws {
        guard o.targetDevices == ["iphone"] || o.targetDevices == ["ipad", "iphone"] else {
            throw XlessError(.ib, "unsupported target devices \(o.targetDevices.joined(separator: ", ")) (verified: iphone, or ipad + iphone)",
                             fix: "set TARGETED_DEVICE_FAMILY to 1 or 1,2")
        }
        guard let v = DottedVersion(o.minimumDeploymentTarget), v >= DottedVersion("15.0")!, v.major <= 27 else {
            throw XlessError(.ib, "unsupported minimum deployment target \(o.minimumDeploymentTarget) (Xcode 27 supports 15.0 to 27.x)",
                             fix: "set the iOS deployment target between 15.0 and 27.x")
        }
    }
}

/// Errors raised while lowering, with the storyboard line when known.
enum LoweringError {
    static let fix = "launch-screen storyboards support: viewController, view, imageView, label, constraints, colors, safe area (see docs/xless-yml.md)"

    static func at(_ line: Int?) -> String { line.map { " at line \($0)" } ?? "" }

    /// Input outside the supported subset.
    static func unsupported(_ what: String, line: Int?) -> XlessError {
        XlessError(.ib, "unsupported \(what)\(at(line))", fix: fix)
    }

    /// Input whose encoding is an open question of docs/research/nib-encoding.md (never guessed, ruling R9).
    static func openQuestion(_ reason: String, line: Int?, fix: String) -> XlessError {
        XlessError(.ib, "unsupported: \(reason)\(at(line)) (see docs/research/nib-encoding.md#open-questions)", fix: fix)
    }

    /// A `YES`/`NO` attribute; nil when absent. Any other spelling is refused.
    /// With `lowercase`, also `true`/`false` (proven per attribute: `ViewRule.lowercaseBooleans`).
    static func bool(_ attributes: [String: String], _ key: String, line: Int?, lowercase: Bool = false) throws -> Bool? {
        switch attributes[key] {
        case nil: return nil
        case "YES": return true
        case "NO": return false
        case "true" where lowercase: return true
        case "false" where lowercase: return false
        case let other?: throw unsupported("\(key)=\"\(other)\" (expected YES or NO)", line: line)
        }
    }

    /// A non-negative number attribute in Xcode's spelling (`XcodeNumber`); nil when absent.
    static func number(_ attributes: [String: String], _ key: String, element: String, line: Int?) throws -> Double? {
        guard let s = attributes[key] else { return nil }
        guard let v = XcodeNumber.parse(s), v >= 0 else {
            throw unsupported("number \(key)=\"\(s)\" on <\(element)> (Xcode writes plain decimals)", line: line)
        }
        return v
    }

    /// Rejects attributes the rules do not know, so that no input is silently dropped.
    static func checkAttributes(_ attributes: [String: String], known: Set<String>, element: String, line: Int?) throws {
        if let bad = attributes.keys.sorted().first(where: { !known.contains($0) }) {
            throw unsupported("attribute \(bad)=\"\(attributes[bad]!)\" on <\(element)>", line: line)
        }
    }
}
