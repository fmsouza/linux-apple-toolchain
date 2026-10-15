import Foundation
import XlessCore

/// xless does not run `project.yml` build scripts; it re-implements the ones it knows (spec §4.5). Tauri's own
/// "Build Rust Code" phase (`tauri ios xcode-script`) is the build stage itself; any other script must be mapped in
/// the overlay (`scripts: { "<name>": ignore }`), so that nothing an app relies on is skipped silently.
public enum ScriptPolicy {
    /// A script is `built-in` when it runs `tauri ios xcode-script`; xless does that step itself (the build stage) and
    /// executes nothing else of the script, so `prepare` says so and `xless tauri inspect` prints the whole script.
    public static let builtInNote = "only its `tauri ios xcode-script` step is reproduced, by the build stage; the rest of the script is not executed"

    /// Each `preBuildScripts` / `postCompileScripts` script's handling: `"built-in"`, the overlay's (`"ignore"`) or nil
    /// when unmapped, with the script's text.
    public static func classify(target: XcodeGenTarget, overlay: TauriOverlay) -> [(name: String, handling: String?, script: String)] {
        (target.preBuildScripts + target.postCompileScripts).map { s in
            (s.name, s.script.contains("tauri ios xcode-script") ? "built-in" : overlay.scripts[s.name]?.rawValue, s.script)
        }
    }

    /// Script name → `"built-in"` or the overlay's handling (`"ignore"`); throws on the first unmapped script.
    public static func check(target: XcodeGenTarget, overlay: TauriOverlay) throws -> [String: String] {
        var out: [String: String] = [:]
        for (name, handling, _) in classify(target: target, overlay: overlay) {
            guard let handling else {
                throw XlessError(.prepare, "project.yml script '\(name)' is not handled",
                                 fix: "add scripts: { \"\(name)\": ignore } to the overlay if xless already covers it, or report it")
            }
            out[name] = handling
        }
        return out
    }
}
