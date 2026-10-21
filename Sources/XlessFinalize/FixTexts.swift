import XlessCore

/// Where the project's settings come from, so that finalize's fix texts point at the right file: xless.yml, a Tauri
/// overlay, a React Native overlay (whose app's Info.plist and deployment target come from the Expo config and the
/// Xcode project, not from xless) or a cargo overlay (whose app's Info.plist is the file its `infoPlist` names).
public enum ProjectKind: Sendable, Equatable {
    case xlessYML, tauri, reactNative, cargo

    var settingsFile: String {
        switch self {
        case .reactNative: "the React Native overlay"
        case .cargo: "the cargo overlay"
        case .xlessYML, .tauri: "xless.yml"
        }
    }
    /// Where an `xcode:` pin is written.
    var pinFile: String { self == .xlessYML ? "xless.yml" : "the overlay" }

    func encryptionMissingFix() -> String {
        switch self {
        case .reactNative:
            "add `usesNonExemptEncryption: false` to the React Native overlay (true if the app uses non-exempt encryption), or set ios.config.usesNonExemptEncryption in the app's Expo config"
        case .cargo:
            "add `usesNonExemptEncryption: false` to the cargo overlay (true if the app uses non-exempt encryption), or add ITSAppUsesNonExemptEncryption to the file named by ios.infoPlist"
        case .xlessYML, .tauri:
            "add `usesNonExemptEncryption: false` to xless.yml (true if the app uses non-exempt encryption), or add ITSAppUsesNonExemptEncryption to the file named by `infoPlist`"
        }
    }

    func encryptionNotBooleanFix() -> String {
        switch self {
        case .reactNative:
            "make it <true/> or <false/> in the app's Info.plist (Expo: ios.config.usesNonExemptEncryption), or remove it and set `usesNonExemptEncryption` in the React Native overlay"
        case .cargo:
            "make it <true/> or <false/> in the file named by ios.infoPlist, or remove it and set `usesNonExemptEncryption` in the cargo overlay"
        case .xlessYML, .tauri:
            "make it <true/> or <false/> in the file named by `infoPlist`, or remove it and set `usesNonExemptEncryption` in xless.yml"
        }
    }

    func encryptionDisagreesFix() -> String {
        switch self {
        case .reactNative:
            "keep one: remove `usesNonExemptEncryption` from the overlay, or the key from the app's Info.plist (Expo: ios.config.usesNonExemptEncryption), or make both values agree"
        case .cargo:
            "keep one: remove `usesNonExemptEncryption` from the cargo overlay, or the key from the file named by ios.infoPlist, or make both values agree"
        case .xlessYML, .tauri:
            "keep one: remove the key from the infoPlist file, or make both values agree"
        }
    }

    func deploymentTarget(binary: String, wanted: String, platform: Platform) -> (cause: String, fix: String) {
        switch self {
        case .reactNative:
            return ("binary deployment target \(binary) ≠ the app target's IPHONEOS_DEPLOYMENT_TARGET \(wanted)",
                    "give the app target one IPHONEOS_DEPLOYMENT_TARGET for the configuration (Expo: expo-build-properties ios.deploymentTarget), in the project and the Pods xcconfigs it is based on, then build again")
        case .cargo:
            return ("binary deployment target \(binary) ≠ the cargo overlay's \(platform.rawValue).minimumOS \(wanted)",
                    "cargo builds with \(platform == .ios ? "IPHONEOS" : "MACOSX")_DEPLOYMENT_TARGET=\(wanted); a build script or C dependency that sets its own deployment target must follow it (or change \(platform.rawValue).minimumOS), then prepare and build again")
        case .xlessYML, .tauri:
            return ("binary deployment target \(binary) ≠ xless.yml minimumOS \(wanted)",
                    "make Package.swift platforms (.\(platform == .ios ? "iOS" : "macOS")(\"\(wanted)\")) match platforms.\(platform.rawValue).minimumOS")
        }
    }

    func privacyManifestFix() -> String {
        switch self {
        case .reactNative:
            "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` to the React Native overlay, or let Expo write the app's own (ios.privacyManifests in the app config) and prepare again"
        case .cargo:
            "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` (relative to the overlay file) to the cargo overlay"
        case .xlessYML, .tauri:
            "add `privacyManifest: path/to/PrivacyInfo.xcprivacy` to xless.yml (or to the Tauri overlay)"
        }
    }
}
