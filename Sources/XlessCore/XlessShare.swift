import Foundation

/// Where xless's data files live (versions.env, docker/, the Dockerfiles, …).
public enum XlessShare {
    public static func root(env: [String: String], executable: URL) throws -> URL {
        let fm = FileManager.default
        if let s = env["XLESS_SHARE"], !s.isEmpty { return URL(fileURLWithPath: s) }
        let exe = executable.resolvingSymlinksInPath()
        let installed = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/xless")
        if fm.fileExists(atPath: installed.appendingPathComponent("versions.env").path) { return installed }
        var dir = exe.deletingLastPathComponent()
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("versions.env").path),
               fm.fileExists(atPath: dir.appendingPathComponent("docker/Dockerfile.base").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw XlessError(.sdk, "cannot find xless's share directory", fix: "reinstall xless (see README) or set XLESS_SHARE")
    }
}
