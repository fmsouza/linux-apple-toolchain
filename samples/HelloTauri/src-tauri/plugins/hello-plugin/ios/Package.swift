// swift-tools-version:5.3

import PackageDescription

let package = Package(
  name: "tauri-plugin-hello",
  platforms: [
    .iOS(.v14),
  ],
  products: [
    .library(
      name: "tauri-plugin-hello",
      type: .static,
      targets: ["tauri-plugin-hello"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api")
  ],
  targets: [
    .target(
      name: "tauri-plugin-hello",
      dependencies: [
        .byName(name: "Tauri")
      ],
      path: "Sources")
  ]
)
