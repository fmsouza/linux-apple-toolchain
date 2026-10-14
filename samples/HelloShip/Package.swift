// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HelloShip",
    platforms: [.iOS("17.0"), .macOS("14.0")],
    products: [.library(name: "HelloShip", targets: ["HelloShip"])],
    targets: [.target(name: "HelloShip", path: "Sources/HelloShip")]
)
