import Foundation
import XlessCore

/// Reads what is actually inside a built `.ipa`, so `upload` declares the versions the binary carries.
public enum IPAInfo {
    /// CFBundleShortVersionString and CFBundleVersion of the app's top-level Info.plist inside `ipa`.
    public static func versions(ipa: URL) throws -> (version: String, build: String) {
        let entries = try Shell.run("unzip", ["-Z1", ipa.path], stage: .upload).stdout.split(separator: "\n").map(String.init)
        guard let entry = entries.first(where: { $0.wholeMatch(of: /Payload\/[^\/]+\.app\/Info\.plist/) != nil }) else {
            throw XlessError(.upload, "\(ipa.lastPathComponent) has no Payload/<App>.app/Info.plist", fix: "run `xless package --platform ios` again")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-ipa-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // unzip -p writes raw bytes; go through a file because Shell captures text.
        try Shell.run("sh", ["-c", "unzip -p \"$0\" \"$1\" > \"$2\"", ipa.path, entry, tmp.path], stage: .upload)
        let info = try Plist.read(tmp, stage: .upload)
        guard let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else {
            throw XlessError(.upload, "\(entry) lacks CFBundleShortVersionString/CFBundleVersion", fix: "re-run from finalize (`xless ship --from finalize`)")
        }
        return (version, build)
    }

    /// The versions to declare to App Store Connect: always the ipa's. An explicit build-number override
    /// (`--build-number` / `XLESS_BUILD_NUMBER`) must agree with the ipa, because it is re-resolved on every run.
    public static func uploadVersions(ipa: URL, buildOverride: String?) throws -> (version: String, build: String) {
        let v = try versions(ipa: ipa)
        if let buildOverride, buildOverride != v.build {
            throw XlessError(.upload, "the .ipa has build \(v.build) but --build-number/XLESS_BUILD_NUMBER is \(buildOverride)",
                             fix: "re-run from finalize or drop the override")
        }
        return v
    }
}
