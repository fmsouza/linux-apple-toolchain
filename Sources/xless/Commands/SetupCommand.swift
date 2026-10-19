import ArgumentParser
import Foundation
import XlessCore
import XlessSDK

/// `xless setup`: the whole image chain (xless-base → xless → xless-tauri → xless-rn) from an Xcode .xip or Xcode.app,
/// with Docker and nothing else: no Mac, no Apple binary executed (xtool reads the Xcode inside xless-base), no checkout.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Build the xless images (xless-base, xless, xless-tauri, xless-rn) from an Xcode .xip or Xcode.app, with Docker.",
        discussion: """
        The Xcode is identified by its content (a .xip's SHA-256, an Xcode.app's version.plist), never by its name. The Darwin \
        SDK is exported into $XDG_CACHE_HOME/xless/sdk/xcode<V>-<B>/ (default ~/.cache/xless) and reused by later runs \
        (--reexport exports again). The Linux xless that goes into xless-base: XLESS_BIN_ARM64 / XLESS_BIN_AMD64 when set, \
        else this xless on a Linux host of that arch, else the release's linux tarball, checked against its SHA256SUMS. \
        Before any step it checks that Docker answers, that buildx is installed, and that the cache and (on Linux) Docker's \
        data root have XLESS_SETUP_DISK_GB free (versions.env's value; the environment's wins).
        """)

    @Option(help: "The Xcode: a downloaded Xcode .xip (any name) or an Xcode.app.") var xcode: String
    @Option(parsing: .upToNextOption, help: "Docker architectures: arm64 and/or amd64 (default: this machine's).") var arch: [String] = []
    @Flag(help: "Export the SDK again even when an export of this Xcode exists.") var reexport = false
    @Flag(help: "Print the plan (each step's command) and run nothing.") var dryRun = false

    func run() async throws {
        do { try setup() } catch let e as XlessError { throw e } catch {
            throw XlessError(.sdk, "\(error.localizedDescription)", fix: "see the output above, then run xless setup again")
        }
    }

    private func setup() throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let share = try XlessShare.root(env: env, executable: exe)
        let versionsEnv = share.appendingPathComponent("versions.env")
        let known = try KnownXcodes.load(versionsEnv: versionsEnv)
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        let host = Self.hostArch
        var archs: [String] = []
        for a in arch.isEmpty ? [host] : arch where !archs.contains(a) {
            guard a == "arm64" || a == "amd64" else {
                throw XlessError(.sdk, "unknown architecture '\(a)'", fix: "pass --arch arm64 and/or --arch amd64")
            }
            archs.append(a)
        }

        if !dryRun { say("==> identifying \(xcode)") }
        let source = try XcodeSource.identify(path: xcode, known: known, cwd: cwd, home: home)
        guard !source.url.path.contains(":") else {
            throw XlessError(.sdk, "\(source.url.path) contains ':', which docker cannot mount", fix: "move or rename it, then run xless setup again")
        }
        let x = source.xcode
        let cacheRoot = SetupPlan.cacheRoot(env: env, home: home)
        let work = fm.temporaryDirectory.appendingPathComponent("xless-setup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        var rootless = false
        if !dryRun {
            // XLESS_SETUP_DISK_GB in the environment (e.g. when most layers are already cached) wins over versions.env's.
            let table = KnownXcodes.parseEnv((try? String(contentsOf: versionsEnv, encoding: .utf8)) ?? "")
            let diskGB = (env["XLESS_SETUP_DISK_GB"].flatMap { Int($0) }) ?? table["XLESS_SETUP_DISK_GB"].flatMap { Int($0) } ?? 120
            rootless = try Self.preflight(cacheRoot: cacheRoot, diskGB: diskGB)
        }
        var binaries: [String: URL] = [:]
        for a in archs { binaries[a] = try binary(arch: a, host: host, env: env, exe: exe, cwd: cwd, home: home, work: work) }

        var steps = dryRun ? [] : try Self.retagSteps(xcode: x, archs: archs, env: env)
        steps += SetupPlan.make(source: source, archs: archs, hostArch: host, share: share, cacheRoot: cacheRoot,
                                xlessBinaries: binaries, reexport: reexport, existing: { fm.fileExists(atPath: $0.path) })
            // Rootless Docker already writes as the calling user from the container's root; `--user` would map to a subuid.
            .map { rootless ? Self.withoutUser($0) : $0 }

        say("==> Xcode \(x.shortVersion) (\(x.build)) from \(source.url.path) (\(source.kind == .xip ? ".xip" : ".app")), for \(archs.joined(separator: ", ")); SDK in \(SetupPlan.sdkDir(cacheRoot: cacheRoot, xcode: x).path)")
        if dryRun {
            say("dry run: the plan, nothing runs")
            for (n, s) in steps.enumerated() {
                say("[\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
                say("    " + s.argv.map(Self.quote).joined(separator: " "))
            }
            return
        }

        let start = Date()
        for (n, s) in steps.enumerated() {
            say("==> [\(n + 1)/\(steps.count)] \(s.title) (\(s.estimate))")
            let t0 = Date()
            try execute(s, xcode: x)
            say("    done in \(Self.minutes(since: t0))")
        }
        say("==> done in \(Self.minutes(since: start)): the images are tagged *:local-<arch>-xcode\(SetupPlan.canonicalVersion(x.shortVersion)) (pin it with xcode: \"\(SetupPlan.canonicalVersion(x.shortVersion))\")")
        say("next: xless docker <project-dir> --build-number 1 --to finalize")
    }

    // MARK: - Steps

    private func execute(_ s: SetupStep, xcode: KnownXcode) throws {
        let fm = FileManager.default
        switch s.action {
        case .run:
            try Shell.run(s.argv[0], Array(s.argv.dropFirst()), stage: .sdk, passthrough: true)
        case let .export(partial, final):
            // A fresh, empty directory the user owns (docker would create a missing one as root); a leftover of an
            // interrupted export is removed first and never reused.
            if fm.fileExists(atPath: partial.path) {
                do { try fm.removeItem(at: partial) } catch {
                    throw XlessError(.sdk, "cannot remove \(partial.path), left by an interrupted export: \(error)",
                                     fix: "delete it (rm -rf '\(partial.path)'), then run xless setup again")
                }
            }
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            try Shell.run(s.argv[0], Array(s.argv.dropFirst()), stage: .sdk, passthrough: true)
            guard fm.fileExists(atPath: partial.appendingPathComponent("darwin.xtoolsdk").path) else {
                throw XlessError(.sdk, "xtool did not produce \(partial.path)/darwin.xtoolsdk", fix: "see xtool's output above")
            }
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: partial, to: final)
        case let .meta(xtoolSDK, out):
            let meta = try ToolchainMetaCollector.collect(xtoolSDK: xtoolSDK, xcode: xcode)
            for p in Platform.allCases { try Requirements.checkSDK(meta.sdk(for: p), platform: p, stage: .sdk) }
            try meta.write(to: out)
        }
    }

    /// Two builds of one Xcode version (a beta and the release): `-xcode<V>` names one of them. As scripts/build-images.sh:
    /// refused when it names another build, unless XLESS_XCODE_RETAG=1, which first gives that build's images their
    /// `-xcode<V>-<B>` tags.
    private static func retagSteps(xcode: KnownXcode, archs: [String], env: [String: String]) throws -> [SetupStep] {
        let v = SetupPlan.canonicalVersion(xcode.shortVersion), suffix = "-xcode\(v)"
        var steps: [SetupStep] = []
        for a in archs {
            guard (try? Shell.run("docker", ["image", "inspect", "xless:local-\(a)\(suffix)"], stage: .sdk)) != nil else { continue }
            let json = (try? Shell.run("docker", ["run", "--rm", "--platform", "linux/\(a)", "--entrypoint", "cat", "xless:local-\(a)\(suffix)",
                                                  "/opt/xless/toolchain-meta.json"], stage: .sdk).stdout) ?? ""
            guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let old = obj["xcodeBuild"] as? String, !old.isEmpty, old != xcode.build else { continue }
            guard env["XLESS_XCODE_RETAG"] == "1" else {
                throw XlessError(.sdk, "the images *:local-\(a)\(suffix) are another build of Xcode \(v) (\(old), this is \(xcode.build)); a pin xcode: \"\(v)\" selects them",
                                 fix: "to point them at this build: XLESS_XCODE_RETAG=1 xless setup … (the \(old) images keep their *-xcode\(v)-\(old) tags)")
            }
            for i in SetupPlan.images where (try? Shell.run("docker", ["image", "inspect", "\(i):local-\(a)\(suffix)"], stage: .sdk)) != nil {
                steps.append(SetupStep(title: "XLESS_XCODE_RETAG=1: keep \(i):local-\(a)\(suffix) (Xcode \(old)) as \(i):local-\(a)\(suffix)-\(old)",
                                       argv: ["docker", "tag", "\(i):local-\(a)\(suffix)", "\(i):local-\(a)\(suffix)-\(old)"], estimate: "seconds"))
            }
        }
        return steps
    }

    // MARK: - Preflight

    /// Docker answers (the cause named: permission denied or no daemon), buildx is there, and the disks have room.
    /// Returns whether the daemon is rootless.
    private static func preflight(cacheRoot: URL, diskGB: Int) throws -> Bool {
        let root: String, rootless: Bool
        do {
            let info = try Shell.run("docker", ["info", "--format", "{{.DockerRootDir}}|{{json .SecurityOptions}}"], stage: .sdk).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            root = String(info.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            rootless = info.contains("name=rootless")
        } catch let e as XlessError {
            let cause = e.cause.lowercased()
            let detail = e.cause.split(separator: "\n").dropFirst().first.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""
            if cause.contains("cannot start docker") {
                throw XlessError(.sdk, "docker is not installed (or not on PATH)",
                                 fix: "install Docker Engine with the buildx plugin: https://docs.docker.com/engine/install/")
            }
            if cause.contains("permission denied") {
                throw XlessError(.sdk, "Docker refused the connection: permission denied on its socket\(detail)",
                                 fix: "add yourself to the docker group (sudo usermod -aG docker $USER), then log out and in again (or run `newgrp docker`)")
            }
            if cause.contains("cannot connect") || cause.contains("is the docker daemon running") {
                throw XlessError(.sdk, "cannot connect to the Docker daemon\(detail)",
                                 fix: "start Docker (sudo systemctl start docker; on a Mac, Docker Desktop or colima start), then run xless setup again")
            }
            throw XlessError(.sdk, "`docker info` failed\(detail)", fix: "check that `docker info` works, then run xless setup again")
        }
        do { try Shell.run("docker", ["buildx", "version"], stage: .sdk) } catch {
            throw XlessError(.sdk, "docker buildx is not available", fix: "install Docker's buildx plugin (e.g. the docker-buildx-plugin package)")
        }
        try checkFree(cacheRoot, needGB: diskGB, what: "the cache (the SDK export)",
                      fix: "free some space, or set XDG_CACHE_HOME to a directory on a larger disk")
        // Docker's data root, when it is on this machine (a Linux host; a Mac's Docker keeps it inside its VM).
        #if os(Linux)
        if !root.isEmpty, FileManager.default.fileExists(atPath: root) {
            try checkFree(URL(fileURLWithPath: root), needGB: diskGB, what: "Docker's data root",
                          fix: "free some space (docker system prune), or move Docker's data-root to a larger disk")
        }
        #endif
        return rootless
    }

    static func withoutUser(_ s: SetupStep) -> SetupStep {
        guard let i = s.argv.firstIndex(of: "--user"), i + 1 < s.argv.count else { return s }
        var argv = s.argv
        argv.removeSubrange(i...(i + 1))
        return SetupStep(title: s.title, argv: argv, estimate: s.estimate, action: s.action)
    }

    private static func checkFree(_ url: URL, needGB: Int, what: String, fix: String) throws {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return }
        let freeGB = free / 1_000_000_000
        guard freeGB >= needGB else {
            throw XlessError(.sdk, "\(freeGB) GB free under \(dir.path) for \(what); xless setup needs about \(needGB) GB", fix: fix)
        }
    }

    // MARK: - The Linux xless for xless-base

    private func binary(arch a: String, host: String, env: [String: String], exe: URL, cwd: URL, home: URL, work: URL) throws -> URL {
        let key = "XLESS_BIN_\(a.uppercased())"
        var bin: URL
        if let p = env[key], !p.isEmpty {
            bin = XcodeSource.absolute(p, cwd: cwd, home: home)
            guard FileManager.default.fileExists(atPath: bin.path) else {
                throw XlessError(.sdk, "\(key)=\(p) does not exist", fix: "point \(key) at a Linux \(a) xless binary")
            }
        } else if Self.isLinux && a == host {
            bin = exe
        } else if dryRun {
            let name = XlessRelease.tarballName(version: XlessVersion.current, dockerArch: a)
            say("(the \(a) xless would come from \(XlessRelease.url(version: XlessVersion.current, file: name).absoluteString))")
            return work.appendingPathComponent("\(a)/xless")
        } else {
            bin = try download(arch: a, key: key, into: work.appendingPathComponent(a))
        }
        if !dryRun {
            guard let got = XlessRelease.elfDockerArch(bin), got == a else {
                throw XlessError(.sdk, "\(bin.path) is not a Linux \(a) xless", fix: "set \(key) to the linux-\(a) xless binary")
            }
        }
        // docker-images.sh takes a file named xless (its directory is the build context).
        if bin.lastPathComponent != "xless" {
            let dir = work.appendingPathComponent("\(a)-bin")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent("xless")
            if !dryRun { try FileManager.default.copyItem(at: bin, to: copy) }
            bin = copy
        }
        return bin
    }

    private func download(arch a: String, key: String, into dir: URL) throws -> URL {
        let version = XlessVersion.current
        guard version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw XlessError(.sdk, "this xless is a development build (\(version)): there is no release to download the linux-\(a) xless from",
                             fix: "set \(key) to a Linux \(a) xless (e.g. one copied out of an xless-base image of that arch)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = XlessRelease.tarballName(version: version, dockerArch: a)
        let tarball = dir.appendingPathComponent(name), sums = dir.appendingPathComponent("SHA256SUMS")
        for (file, to) in [(name, tarball), ("SHA256SUMS", sums)] {
            let url = XlessRelease.url(version: version, file: file).absoluteString
            say("==> downloading \(url)")
            do { try Shell.run("curl", ["-fsSL", "--retry", "3", "-o", to.path, url], stage: .sdk) } catch let e as XlessError {
                throw XlessError(.sdk, "cannot download \(url): \(e.cause)", fix: "check the network, or set \(key) to a Linux \(a) xless")
            }
        }
        try XlessRelease.verify(tarball: tarball, name: name, sums: try String(contentsOf: sums, encoding: .utf8))
        return try XlessRelease.extractBinary(tarball: tarball, version: version, dockerArch: a, into: dir)
    }

    // MARK: - Helpers

    static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    static var isLinux: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    static func quote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@,+%{}".contains($0) }) && !s.isEmpty
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func minutes(since t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// Unbuffered, so the lines stay in order with the steps' own output.
private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
