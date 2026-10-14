/// Human explanations for App Store Connect processing errors seen with non-Xcode builds.
public enum KnownIssues {
    static let table: [(needles: [String], explanation: String)] = [
        (["90725"], "SDK version in a binary's LC_BUILD_VERSION was not patched — xless bug, please report with `xless inspect` output"),
        (["90189", "90062", "bundle version must be higher", "Redundant Binary"],
         "this build number was already uploaded, or is not higher than an earlier upload of this version — use a build number higher than every previous upload from any machine (e.g. XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))) or bump `version`"),
        (["90717"], "an app icon has an alpha channel — re-export it without transparency"),
        (["90022", "90023", "90713", "90704"], "app icon problem — see docs/research/parity-known-gaps.md"),
        (["90135"], "a binary carries a secure timestamp — App Store signing must use --timestamp-url none (xless bug if you see this)"),
        (["90562"], "Assets.car is invalid — retry without `assets:` to isolate, and report to xtool-org/AssetKit"),
        (["90534", "90111", "Invalid Toolchain"], "App Store Connect rejected the build toolchain metadata — compare `xless inspect` with an Xcode build (scripts/parity.sh)"),
        (["90683"], "a usage-description string (NS…UsageDescription) is missing from Info.plist — add it via infoPlist in xless.yml"),
        (["91053", "privacy manifest", "PrivacyInfo"], "the privacy manifest is missing a required-reason API declaration — update PrivacyInfo.xcprivacy"),
        (["90208", "MinimumOSVersion"], "Info.plist MinimumOSVersion disagrees with the binary — align Package.swift platforms with xless.yml"),
    ]

    public static func explain(_ message: String) -> String? {
        let lower = message.lowercased()
        return table.first { $0.needles.contains { lower.contains($0.lowercased()) } }?.explanation
    }
}
