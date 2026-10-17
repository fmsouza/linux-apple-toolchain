import XlessCore

/// Where the project's settings come from, so that finalize's fix texts point at the right file: xless.yml, a Tauri
/// overlay or a React Native overlay (whose app's Info.plist and deployment target come from the Expo config and the
/// Xcode project, not from xless).
public enum ProjectKind: Sendable, Equatable {
    case xlessYML, tauri, reactNative

    var settingsFile: String { self == .reactNative ? "the React Native overlay" : "xless.yml" }
    /// Where an `xcode:` pin is written.
    var pinFile: String { self == .xlessYML ? "xless.yml" : "the overlay" }

    func encryptionMissingFix() -> String {
        self == .reactNative
            ? "add `usesNonExemptEncryption: false` to the React Native overlay (true if the app uses non-exempt encryption), or set ios.config.usesNonExemptEncryption in the app's Expo config"
            : "add `usesNonExemptEncryption: false` to xless.yml (true if the app uses non-exempt encryption), or add ITSAppUsesNonExemptEncryption to the file named by `infoPlist`"
    }

    func encryptionNotBooleanFix() -> String {
        self == .reactNative
            ? "make it <true/> or <false/> in the app's Info.plist (Expo: ios.config.usesNonExemptEncryption), or remove it and set `usesNonExemptEncryption` in the React Native overlay"
            : "make it <true/> or <false/> in the file named by `infoPlist`, or remove it and set `usesNonExemptEncryption` in xless.yml"
    }

    func encryptionDisagreesFix() -> String {
        self == .reactNative
            ? "keep one: remove `usesNonExemptEncryption` from the overlay, or the key from the app's Info.plist (Expo: ios.config.usesNonExemptEncryption), or make both values agree"
            : "keep one: remove the key from the infoPlist file, or make both values agree"
    }

    func deploymentTarget(binary: String, wanted: String, platform: Platform) -> (cause: String, fix: String) {
        switch self {
        case .reactNative:
            return ("binary deployment target \(binary) ≠ the app target's IPHONEOS_DEPLOYMENT_TARGET \(wanted)",
                    "give the app target one IPHONEOS_DEPLOYMENT_TARGET for the configuration (Expo: expo-build-properties ios.deploymentTarget), in the project and the Pods xcconfigs it is based on, then build again")
        case .xlessYML, .tauri:
            return ("binary deployment target \(binary) ≠ xless.yml minimumOS \(wanted)",
                    "make Package.swift platforms (.\(platform == .ios ? "iOS" : "macOS")(\"\(wanted)\")) match platforms.\(platform.rawValue).minimumOS")
        }
    }

    func privacyManifestFix() -> String {
        self == .reactNative
            ? "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` to the React Native overlay, or let Expo write the app's own (ios.privacyManifests in the app config) and prepare again"
            : "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` to xless.yml (or to the Tauri overlay)"
    }
}
