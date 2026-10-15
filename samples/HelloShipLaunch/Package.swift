// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelloShipLaunch",
    platforms: [.iOS("17.0"), .macOS("14.0")],
    products: [.library(name: "HelloShipLaunch", targets: ["HelloShipLaunch"])],
    targets: [.target(name: "HelloShipLaunch", path: "Sources/HelloShipLaunch")]
)
