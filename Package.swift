// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "xless",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "xless", targets: ["xless"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.0.0"),
        .package(path: "ThirdParty/AssetKit"), // vendored, patched AssetKit; see ThirdParty/AssetKit/README.md
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"), // already pulled in by AssetKit
    ],
    targets: [
        .target(name: "XlessCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .target(name: "XlessSDK", dependencies: ["XlessCore"]),
        .target(name: "XlessMachO"),
        .target(name: "XlessBuild", dependencies: ["XlessCore", "XlessMachO"]),
        .target(name: "XlessAssets", dependencies: [
            "XlessCore", "XlessMachO", "XlessIB",
            .product(name: "AssetKit", package: "AssetKit"),
            .product(name: "PNG", package: "swift-png"),
        ]),
        .target(name: "XlessIB", dependencies: ["XlessCore"]),
        .target(name: "XlessFinalize", dependencies: ["XlessCore", "XlessMachO"]),
        .target(name: "XlessASC", dependencies: [
            "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "XlessSign", dependencies: [
            "XlessCore", "XlessASC",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .target(name: "XlessPackage", dependencies: ["XlessCore", "XlessSign"]),
        .executableTarget(name: "xless", dependencies: [
            "XlessCore", "XlessSDK", "XlessBuild", "XlessAssets", "XlessFinalize", "XlessSign", "XlessASC", "XlessPackage", "XlessIB",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // Research tool: compares the storyboard compiler with ibtool outputs (scripts/ib-corpus/differential.py).
        // Not a product: `--product xless` (image builds) skips it; only `swift run IBDifferential` builds it.
        .executableTarget(name: "IBDifferential", dependencies: ["XlessIB", "XlessCore"]),
        .testTarget(name: "XlessCoreTests", dependencies: ["XlessCore"]),
        .testTarget(name: "XlessSDKTests", dependencies: ["XlessSDK", "XlessCore"]),
        .testTarget(name: "XlessBuildTests", dependencies: ["XlessBuild", "XlessCore"]),
        .testTarget(name: "XlessAssetsTests", dependencies: [
            "XlessAssets", "XlessCore", "XlessMachO",
            .product(name: "PNG", package: "swift-png"),
        ]),
        .testTarget(name: "XlessFinalizeTests", dependencies: ["XlessFinalize", "XlessCore", "XlessMachO"]),
        .testTarget(name: "XlessASCTests", dependencies: [
            "XlessASC", "XlessCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessSignTests", dependencies: [
            "XlessSign", "XlessASC", "XlessCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "XlessPackageTests", dependencies: ["XlessPackage", "XlessCore"]),
        .testTarget(name: "XlessIBTests", dependencies: ["XlessIB", "XlessCore"]),
        .testTarget(name: "XlessMachOTests", dependencies: ["XlessMachO"]),
    ]
)
