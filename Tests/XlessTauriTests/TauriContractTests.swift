import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

/// An app root with `src-tauri/Cargo.lock` pinning `tauri`, a package.json and, optionally, one JS lockfile.
private func app(tauri: String, packageJSON: String = #"{"devDependencies":{"@tauri-apps/cli":"~2.12.0"}}"#,
                 lock: (name: String, text: String)? = nil) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("contract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src-tauri"), withIntermediateDirectories: true)
    try """
        [[package]]
        name = "tao"
        version = "0.35.0"

        [[package]]
        name = "tauri"
        version = "\(tauri)"
        source = "registry+https://github.com/rust-lang/crates.io-index"

        [[package]]
        name = "tauri-build"
        version = "2.7.0"
        """.write(to: root.appendingPathComponent("src-tauri/Cargo.lock"), atomically: true, encoding: .utf8)
    try packageJSON.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    if let lock { try lock.text.write(to: root.appendingPathComponent(lock.name), atomically: true, encoding: .utf8) }
    return root
}

private let pnpmLock = """
    lockfileVersion: '9.0'

    importers:

      .:
        devDependencies:
          '@tauri-apps/cli':
            specifier: 2.12.3
            version: 2.12.3

    packages:

      '@tauri-apps/cli-darwin-arm64@2.12.3':
        resolution: {integrity: sha512-x}

      '@tauri-apps/cli@2.12.3':
        resolution: {integrity: sha512-y}
    """

@Suite struct TauriContractTests {
    @Test func acceptsTwelvePatchReleases() throws {
        try TauriContract.check(source: app(tauri: "2.12.0"))
        try TauriContract.check(source: app(tauri: "2.12.3", lock: ("pnpm-lock.yaml", pnpmLock)))
    }

    @Test func refusesOtherMinor() throws {
        do {
            try TauriContract.check(source: app(tauri: "2.13.0"))
            Issue.record("2.13.0 accepted")
        } catch let e as XlessError {
            #expect(e.stage == .prepare)
            #expect(e.cause == "Tauri 2.13.0 / CLI 2.12.0 is outside the contract xless supports (2.12.x)")
            #expect(e.fix.contains("make tauri-reference") && e.fix.contains("TauriContract.supported"))
        }
    }

    @Test func refusesOtherCLI() throws {
        let lock = #"{"lockfileVersion":3,"packages":{"node_modules/@tauri-apps/cli":{"version":"2.11.1"}}}"#
        #expect(throws: XlessError.self) { try TauriContract.check(source: app(tauri: "2.12.0", lock: ("package-lock.json", lock))) }
    }

    @Test func fallsBackToPackageJSONRange() throws {
        // A lockfile without the CLI entry: the package.json range `~2.12.0` decides.
        let root = try app(tauri: "2.12.0", lock: ("yarn.lock", "# yarn lockfile v1\n\n\"left-pad@^1.0.0\":\n  version \"1.3.0\"\n"))
        #expect(try TauriContract.cliVersion(appRoot: root) == "2.12.0")
        try TauriContract.check(source: root)
    }

    @Test func readsEachLockfileFormat() throws {
        #expect(try TauriContract.cliVersion(appRoot: app(tauri: "2.12.0", lock: ("pnpm-lock.yaml", pnpmLock))) == "2.12.3")
        let npm = #"{"lockfileVersion":3,"packages":{"":{},"node_modules/@tauri-apps/cli":{"version":"2.12.1"}}}"#
        #expect(try TauriContract.cliVersion(appRoot: app(tauri: "2.12.0", lock: ("package-lock.json", npm))) == "2.12.1")
        let yarn = "\"@tauri-apps/cli@^2.12.0\":\n  version \"2.12.2\"\n  resolved \"https://x\"\n"
        #expect(try TauriContract.cliVersion(appRoot: app(tauri: "2.12.0", lock: ("yarn.lock", yarn))) == "2.12.2")
        let berry = "\"@tauri-apps/cli@npm:^2.12.0\":\n  version: 2.12.4\n  resolution: \"x\"\n"
        #expect(try TauriContract.cliVersion(appRoot: app(tauri: "2.12.0", lock: ("yarn.lock", berry))) == "2.12.4")
    }

    @Test func readsTauriFromCargoLock() {
        #expect(TauriContract.tauriVersion(cargoLock: "[[package]]\nname = \"tauri\"\nversion = \"2.12.0\"\n") == "2.12.0")
        #expect(TauriContract.tauriVersion(cargoLock: "[[package]]\nname = \"tauri-build\"\nversion = \"2.7.0\"\n") == nil)
    }

    @Test func refusesUnknownVersions() throws {
        let noCLI = try app(tauri: "2.12.0", packageJSON: "{}")
        #expect(throws: XlessError.self) { try TauriContract.check(source: noCLI) }
        let noLock = try app(tauri: "2.12.0")
        try FileManager.default.removeItem(at: noLock.appendingPathComponent("src-tauri/Cargo.lock"))
        #expect(throws: XlessError.self) { try TauriContract.check(source: noLock) }
    }
}
