import Foundation
import XlessCore
import XlessMachO

/// tauri-bundler 2.x's macOS `.app` (bundle/macos/app.rs), re-done: `Contents/MacOS/<main binary>`, `Contents/Info.plist`,
/// `Contents/Resources/<icon>.icns`, `bundle.resources` and `bundle.macOS.frameworks`. Layout and values:
/// docs/research/tauri-ios-contract.md, "macOS (desktop)" › Bundle; per-target resources: "macOS — spike B".
public enum TauriMacBundler {
    public typealias Resource = (source: URL, target: String)

    // MARK: Info.plist

    /// tauri-bundler's `create_info_plist`, in its key order; then Info.plist next to the config and
    /// `bundle.macOS.infoPlist` (a path or an inline dictionary) merged over it, then the overlay's `macos.infoPlist` (later wins). `resolved.mainBinaryName` must
    /// be known (buildMac fills it from cargo metadata when tauri.conf.json has none).
    public static func infoPlist(resolved r: ResolvedTauriMac, workRoot: URL) throws -> [String: Any] {
        let pc = try r.config.platform(.macos)
        let bundle = r.tauri.raw["bundle"] as? [String: Any] ?? [:]
        let mac = bundle["macOS"] as? [String: Any] ?? [:]
        guard let executable = r.mainBinaryName else {
            throw XlessError(.build, "the main binary name of \(r.tauriDir) is unknown", fix: "set mainBinaryName in tauri.conf.json")
        }
        var p: [String: Any] = [
            "CFBundleDevelopmentRegion": "English",
            "CFBundleDisplayName": pc.product,
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": r.config.bundleID(for: .macos),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": mac["bundleName"] as? String ?? pc.product,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": r.config.version,
            // Tauri's default. `bundle.macOS.bundleVersion` is not honoured: finalize stamps the overlay's `build:` over it.
            "CFBundleVersion": r.config.version,
            "CSResourcesFileMapped": true,
            "LSMinimumSystemVersion": pc.minimumOS,
        ]
        if let category = bundle["category"] as? String { p["LSApplicationCategoryType"] = try categoryType(category) }
        for (k, v) in try fileAssociationsPlist(bundle["fileAssociations"]) { p[k] = v }
        if let icns = iconFile(bundle) { p["CFBundleIconFile"] = (icns as NSString).lastPathComponent }
        p["LSRequiresCarbon"] = true
        p["NSHighResolutionCapable"] = true
        if let copyright = bundle["copyright"] as? String { p["NSHumanReadableCopyright"] = copyright }
        if let domain = mac["exceptionDomain"] as? String {
            p["NSAppTransportSecurity"] = ["NSExceptionDomains": [domain: ["NSExceptionAllowsInsecureHTTPLoads": true, "NSIncludesSubdomains": true]]]
        }

        let tauriDir = workRoot.appendingPathComponent(r.tauriDir)
        var user: [URL] = []
        let next = tauriDir.appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath: next.path) { user.append(next) }
        if let path = mac["infoPlist"] as? String { user.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : tauriDir.appendingPathComponent(path)) }
        for url in user {
            for (k, v) in try Plist.read(url, stage: .build) { p[k] = v }
        }
        if let inline = mac["infoPlist"] as? [String: Any] { for (k, v) in inline { p[k] = v } }
        if let path = r.config.infoPlist {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workRoot.appendingPathComponent(path)
            for (k, v) in try Plist.read(url, stage: .build) { p[k] = v }
        }
        // `Contents/MacOS/<CFBundleExecutable>`: one plain file name, never a path out of the bundle.
        guard let name = p["CFBundleExecutable"] as? String, isFileName(name) else {
            throw XlessError(.build, "the executable name '\(p["CFBundleExecutable"].map { "\($0)" } ?? "")' is not a single file name",
                             fix: "set mainBinaryName in tauri.conf.json (or CFBundleExecutable in a merged Info.plist) to a name without '/', not '.' or '..'")
        }
        return p
    }

    /// A non-empty path component: no `/`, not `.` or `..`.
    static func isFileName(_ s: String) -> Bool { !s.isEmpty && !s.contains("/") && s != "." && s != ".." && !s.contains("\0") }

    /// tauri-bundler `category.rs`: `LSApplicationCategoryType` for a `bundle.category`. The input is lower-cased, a
    /// `public.app-category.` prefix and spaces and hyphens are dropped, then it is looked up in Tauri's alias table.
    /// Tauri refuses an unknown category too ("invalid category"); its fuzzy "did you mean" is not reproduced.
    public static func categoryType(_ category: String) throws -> String {
        var key = category.lowercased()
        if key.hasPrefix("public.app-category.") { key = String(key.dropFirst("public.app-category.".count)) }
        key = key.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard let name = categoryAliases[key], let uti = categoryTypes[name] else {
            throw XlessError(.build, "bundle.category '\(category)' is not a Tauri app category",
                             fix: "use one of \(categoryTypes.keys.sorted().joined(separator: ", ")) in tauri.conf.json")
        }
        return uti
    }

    /// tauri-bundler `AppCategory::macos_application_category_type`.
    static let categoryTypes: [String: String] = [
        "Business": "public.app-category.business", "DeveloperTool": "public.app-category.developer-tools",
        "Education": "public.app-category.education", "Entertainment": "public.app-category.entertainment",
        "Finance": "public.app-category.finance", "Game": "public.app-category.games",
        "ActionGame": "public.app-category.action-games", "AdventureGame": "public.app-category.adventure-games",
        "ArcadeGame": "public.app-category.arcade-games", "BoardGame": "public.app-category.board-games",
        "CardGame": "public.app-category.card-games", "CasinoGame": "public.app-category.casino-games",
        "DiceGame": "public.app-category.dice-games", "EducationalGame": "public.app-category.educational-games",
        "FamilyGame": "public.app-category.family-games", "KidsGame": "public.app-category.kids-games",
        "MusicGame": "public.app-category.music-games", "PuzzleGame": "public.app-category.puzzle-games",
        "RacingGame": "public.app-category.racing-games", "RolePlayingGame": "public.app-category.role-playing-games",
        "SimulationGame": "public.app-category.simulation-games", "SportsGame": "public.app-category.sports-games",
        "StrategyGame": "public.app-category.strategy-games", "TriviaGame": "public.app-category.trivia-games",
        "WordGame": "public.app-category.word-games", "GraphicsAndDesign": "public.app-category.graphics-design",
        "HealthcareAndFitness": "public.app-category.healthcare-fitness", "Lifestyle": "public.app-category.lifestyle",
        "Medical": "public.app-category.medical", "Music": "public.app-category.music", "News": "public.app-category.news",
        "Photography": "public.app-category.photography", "Productivity": "public.app-category.productivity",
        "Reference": "public.app-category.reference", "SocialNetworking": "public.app-category.social-networking",
        "Sports": "public.app-category.sports", "Travel": "public.app-category.travel", "Utility": "public.app-category.utilities",
        "Video": "public.app-category.video", "Weather": "public.app-category.weather",
    ]

    /// tauri-bundler `CATEGORY_STRINGS` (canonicalized input → category).
    static let categoryAliases: [String: String] = [
        "actiongame": "ActionGame", "actiongames": "ActionGame", "adventuregame": "AdventureGame", "adventuregames": "AdventureGame",
        "arcadegame": "ArcadeGame", "arcadegames": "ArcadeGame", "boardgame": "BoardGame", "boardgames": "BoardGame",
        "business": "Business", "cardgame": "CardGame", "cardgames": "CardGame", "casinogame": "CasinoGame", "casinogames": "CasinoGame",
        "developer": "DeveloperTool", "developertool": "DeveloperTool", "developertools": "DeveloperTool", "development": "DeveloperTool",
        "dicegame": "DiceGame", "dicegames": "DiceGame", "education": "Education", "educationalgame": "EducationalGame",
        "educationalgames": "EducationalGame", "entertainment": "Entertainment", "familygame": "FamilyGame", "familygames": "FamilyGame",
        "finance": "Finance", "fitness": "HealthcareAndFitness", "game": "Game", "games": "Game", "graphicdesign": "GraphicsAndDesign",
        "graphicsanddesign": "GraphicsAndDesign", "graphicsdesign": "GraphicsAndDesign", "healthcareandfitness": "HealthcareAndFitness",
        "healthcarefitness": "HealthcareAndFitness", "kidsgame": "KidsGame", "kidsgames": "KidsGame", "lifestyle": "Lifestyle",
        "logicgame": "PuzzleGame", "medical": "Medical", "medicalsoftware": "Medical", "music": "Music", "musicgame": "MusicGame",
        "musicgames": "MusicGame", "news": "News", "photography": "Photography", "productivity": "Productivity",
        "puzzlegame": "PuzzleGame", "puzzlegames": "PuzzleGame", "racinggame": "RacingGame", "racinggames": "RacingGame",
        "reference": "Reference", "roleplaying": "RolePlayingGame", "roleplayinggame": "RolePlayingGame",
        "roleplayinggames": "RolePlayingGame", "rpg": "RolePlayingGame", "simulationgame": "SimulationGame",
        "simulationgames": "SimulationGame", "socialnetwork": "SocialNetworking", "socialnetworking": "SocialNetworking",
        "sports": "Sports", "sportsgame": "SportsGame", "sportsgames": "SportsGame", "strategygame": "StrategyGame",
        "strategygames": "StrategyGame", "travel": "Travel", "triviagame": "TriviaGame", "triviagames": "TriviaGame",
        "utilities": "Utility", "utility": "Utility", "video": "Video", "weather": "Weather", "wordgame": "WordGame", "wordgames": "WordGame",
    ]

    /// `tauri_utils::config::file_associations_plist` (macOS and iOS): `UTExportedTypeDeclarations` for associations with
    /// an `exportedType`, and `CFBundleDocumentTypes`. Empty for no associations.
    /// LSItemContentTypes: Tauri collects them in a HashSet, so its order varies between builds; here it is explicit
    /// `contentTypes` first, then the UTIs inferred from the extensions, then from `mimeType`, without duplicates.
    public static func fileAssociationsPlist(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let list = value as? [[String: Any]] else {
            throw XlessError(.build, "bundle.fileAssociations is not a list of objects", fix: "fix bundle.fileAssociations in tauri.conf.json")
        }
        guard !list.isEmpty else { return [:] }
        var exported: [[String: Any]] = [], documents: [[String: Any]] = []
        for a in list {
            let exts = (a["ext"] as? [String] ?? []).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            let mime = a["mimeType"] as? String ?? a["mime-type"] as? String
            let exportedType = a["exportedType"] as? [String: Any] ?? a["exported-type"] as? [String: Any]
            if let t = exportedType, let id = t["identifier"] as? String {
                var d: [String: Any] = ["UTTypeIdentifier": id]
                if let desc = a["description"] as? String { d["UTTypeDescription"] = desc }
                if let conforms = t["conformsTo"] as? [String] ?? t["conforms-to"] as? [String] { d["UTTypeConformsTo"] = conforms }
                var spec: [String: Any] = ["public.filename-extension": exts]
                if let mime { spec["public.mime-type"] = mime }
                d["UTTypeTagSpecification"] = spec
                exported.append(d)
            }
            var doc: [String: Any] = [:]
            if !exts.isEmpty { doc["CFBundleTypeExtensions"] = exts }
            var types: [String] = []
            func add(_ t: String?) { if let t, !types.contains(t) { types.append(t) } }
            if let id = exportedType?["identifier"] as? String {
                add(id)
            } else {
                for t in a["contentTypes"] as? [String] ?? a["content-types"] as? [String] ?? [] { add(t) }
                for e in exts { add(extensionUTI(e)) }
                if let mime { add(mimeUTI(mime)) }
            }
            if !types.isEmpty { doc["LSItemContentTypes"] = types }
            doc["CFBundleTypeName"] = a["name"] as? String ?? exts.first ?? ""
            doc["CFBundleTypeRole"] = a["role"] as? String ?? "Editor"
            doc["LSHandlerRank"] = a["rank"] as? String ?? "Default"
            documents.append(doc)
        }
        var out: [String: Any] = ["CFBundleDocumentTypes": documents]
        if !exported.isEmpty { out["UTExportedTypeDeclarations"] = exported }
        return out
    }

    /// tauri-utils `extension_to_uti`.
    static func extensionUTI(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "png": "public.png"
        case "jpg", "jpeg": "public.jpeg"
        case "gif": "com.compuserve.gif"
        case "bmp": "com.microsoft.bmp"
        case "tiff", "tif": "public.tiff"
        case "ico": "com.microsoft.ico"
        case "heic", "heif": "public.heif-standard-image"
        case "webp": "org.webmproject.webp"
        case "svg": "public.svg-image"
        case "mp4", "mkv": "public.mpeg-4"
        case "mov": "com.apple.quicktime-movie"
        case "avi": "public.avi"
        case "mp3": "public.mp3"
        case "wav": "com.microsoft.waveform-audio"
        case "aac": "public.aac-audio"
        case "m4a": "public.mpeg-4-audio"
        case "pdf": "com.adobe.pdf"
        case "txt": "public.plain-text"
        case "rtf": "public.rtf"
        case "html", "htm": "public.html"
        case "json": "public.json"
        case "xml": "public.xml"
        default: nil
        }
    }

    /// tauri-utils `mime_type_to_uti`.
    static func mimeUTI(_ mime: String) -> String? {
        switch mime {
        case "image/png": "public.png"
        case "image/jpeg", "image/jpg": "public.jpeg"
        case "image/gif": "com.compuserve.gif"
        case "image/bmp": "com.microsoft.bmp"
        case "image/tiff": "public.tiff"
        case "image/heic", "image/heif": "public.heif-standard-image"
        case "image/webp": "org.webmproject.webp"
        case "image/svg+xml": "public.svg-image"
        case let m where m.hasPrefix("image/"): "public.image"
        case "video/mp4": "public.mpeg-4"
        case "video/quicktime": "com.apple.quicktime-movie"
        case "video/x-msvideo": "public.avi"
        case let m where m.hasPrefix("video/"): "public.movie"
        case "audio/mpeg", "audio/mp3": "public.mp3"
        case "audio/wav", "audio/wave": "com.microsoft.waveform-audio"
        case "audio/aac": "public.aac-audio"
        case "audio/mp4": "public.mpeg-4-audio"
        case let m where m.hasPrefix("audio/"): "public.audio"
        case "application/pdf": "com.adobe.pdf"
        case "text/plain": "public.plain-text"
        case "text/rtf": "public.rtf"
        case "text/html": "public.html"
        case "application/json": "public.json"
        case "application/xml", "text/xml": "public.xml"
        default: nil
        }
    }

    /// The first `.icns` in `bundle.icon` (tauri-bundler copies it under its own name). Tauri would render one from the
    /// PNGs when there is none; xless requires it (spec §2).
    static func iconFile(_ bundle: [String: Any]) -> String? {
        (bundle["icon"] as? [String])?.first { $0.lowercased().hasSuffix(".icns") }
    }

    // MARK: resources

    /// `tauri_utils::resources::ResourcePaths` for `bundle.resources` (a list or a source → target map), paths relative to
    /// `tauriDir`. A list entry keeps its path (`..` → `_up_`, a root → `_root_`, `.` dropped); a directory is walked (files
    /// only, dot files included, sorted); an entry with `*` is a glob (`*`, `?`, `[…]`, `**`) that matches files only,
    /// sorted. A map entry puts a file at its target (an empty target keeps the file name), a directory's tree under the
    /// target and a glob's matches under the target by file name.
    /// Two entries that map to the same bundle path are refused (Tauri would keep whichever it copies last).
    public static func resourceMappings(resources: Any?, tauriDir: URL) throws -> [Resource] {
        let perEntry: [(entry: String, resources: [Resource])]
        switch resources {
        case nil: return []
        case let list as [String]: perEntry = try list.map { ($0, try entries($0, target: nil, tauriDir: tauriDir)) }
        case let map as [String: String]:
            perEntry = try map.keys.sorted().map { ($0, try entries($0, target: relpath(map[$0]!), tauriDir: tauriDir)) }
        default:
            throw XlessError(.build, "bundle.resources is neither a list of paths nor a map of source to target paths", fix: "fix bundle.resources in tauri.conf.json")
        }
        var owner: [String: String] = [:]
        for (entry, list) in perEntry {
            for r in list {
                if let first = owner[r.target] {
                    throw XlessError(.build, "bundle.resources entries '\(first)' and '\(entry)' both put a file at '\(r.target)'",
                                     fix: "give each resource its own target path in bundle.resources")
                }
                owner[r.target] = entry
            }
        }
        return perEntry.flatMap(\.resources)
    }

    private static func entries(_ pattern: String, target: String?, tauriDir: URL) throws -> [Resource] {
        let fm = FileManager.default
        func notFound() -> XlessError {
            XlessError(.build, "bundle.resources entry '\(pattern)' not found under \(tauriDir.path) (checked after cargo)",
                       fix: "check the path in tauri.conf.json; files a build script stages must exist after cargo build")
        }
        func url(_ path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : tauriDir.appendingPathComponent(path) }
        func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : b.isEmpty ? a : "\(a)/\(b)" }

        // As tauri-utils: only an entry with `*` is a glob (then `?` and `[…]` match too); anything else is a path.
        if pattern.contains("*") {
            let matches = try glob(pattern, tauriDir: tauriDir)
            guard !matches.isEmpty else { throw notFound() }
            return matches.map { m in (url(m), target.map { join($0, (m as NSString).lastPathComponent) } ?? relpath(m)) }
        }
        let path = normalize(pattern)
        let src = url(path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { throw notFound() }
        if isDir.boolValue {
            return walk(src).map { rel in
                (src.appendingPathComponent(rel), target.map { join($0, rel) } ?? relpath(join(path, rel)))
            }
        }
        guard let target else { return [(src, relpath(path))] }
        return [(src, target.isEmpty ? src.lastPathComponent : target)]
    }

    /// Regular files (and symlinks to them) under `dir`, relative and sorted.
    static func walk(_ dir: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func visit(_ rel: String) {
            let here = rel.isEmpty ? dir : dir.appendingPathComponent(rel)
            for name in ((try? fm.contentsOfDirectory(atPath: here.path)) ?? []).sorted() {
                let child = rel.isEmpty ? name : "\(rel)/\(name)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.appendingPathComponent(child).path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { visit(child) } else { out.append(child) }
            }
        }
        visit("")
        return out
    }

    /// The `glob` crate as tauri-utils uses it (default options: `*` also matches a leading dot; `**` matches any number
    /// of directories). Returns matching files, as paths in the pattern's form, sorted.
    static func glob(_ pattern: String, tauriDir: URL) throws -> [String] {
        let fm = FileManager.default
        let absolute = pattern.hasPrefix("/")
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        var results: [String] = []
        func full(_ rel: String) -> String { absolute ? "/" + rel : (rel.isEmpty ? tauriDir.path : tauriDir.appendingPathComponent(rel).path) }
        func isDir(_ rel: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: full(rel), isDirectory: &d) && d.boolValue }
        func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : "\(a)/\(b)" }
        func step(_ i: Int, _ rel: String) {
            if i == parts.count {
                if !rel.isEmpty, FileManager.default.fileExists(atPath: full(rel)), !isDir(rel) { results.append(rel) }
                return
            }
            let part = parts[i]
            if part == "**" {
                step(i + 1, rel)
                for name in ((try? fm.contentsOfDirectory(atPath: full(rel))) ?? []).sorted() where isDir(join(rel, name)) {
                    step(i, join(rel, name))
                }
            } else if part == ".." || !(part.contains("*") || part.contains("?") || part.contains("[")) {
                step(i + 1, join(rel, part))
            } else {
                for name in ((try? fm.contentsOfDirectory(atPath: full(rel))) ?? []).sorted() where wildcard(Array(part), Array(name)) {
                    step(i + 1, join(rel, name))
                }
            }
        }
        step(0, "")
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }.sorted().map { absolute ? "/" + $0 : $0 }
    }

    /// One path component against a glob component (`*`, `?`, `[abc]`, `[a-z]`, `[!a]`).
    static func wildcard(_ p: [Character], _ s: [Character]) -> Bool {
        func match(_ pi: Int, _ si: Int) -> Bool {
            if pi == p.count { return si == s.count }
            switch p[pi] {
            case "*": return (si...s.count).contains { match(pi + 1, $0) }
            case "?": return si < s.count && match(pi + 1, si + 1)
            case "[":
                guard si < s.count, let close = p[(pi + 1)...].firstIndex(of: "]") else { return si < s.count && s[si] == "[" && match(pi + 1, si + 1) }
                var set = Array(p[(pi + 1)..<close]), negate = false
                if set.first == "!" { negate = true; set.removeFirst() }
                var hit = false, k = 0
                while k < set.count {
                    // A reversed range (`[z-a]`) matches nothing.
                    if k + 2 < set.count, set[k + 1] == "-" { hit = hit || (set[k] <= set[k + 2] && (set[k]...set[k + 2]).contains(s[si])); k += 3 }
                    else { hit = hit || set[k] == s[si]; k += 1 }
                }
                return hit != negate && match(close + 1, si + 1)
            default: return si < s.count && p[pi] == s[si] && match(pi + 1, si + 1)
            }
        }
        return match(0, 0)
    }

    /// `normalize`: `.` dropped, `..` kept, a leading `/` kept.
    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + parts : parts
    }

    /// `resource_relpath`: a root → `_root_`, `..` → `_up_`, `.` dropped.
    static func relpath(_ path: String) -> String {
        var out = path.hasPrefix("/") ? ["_root_"] : []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) where c != "." { out.append(c == ".." ? "_up_" : String(c)) }
        return out.joined(separator: "/")
    }

    /// After one target's cargo run: copies every resource into `dir/<target>`, from cargo's per-target copy
    /// (`<target dir>/<triple>/release/<target>`, written by tauri-build) when there is one, else from its source. The
    /// shared source is not read again after the next target's build, which may overwrite it (spike B). Returns the targets.
    public static func snapshotResources(_ resources: [Resource], cargoRelease: URL, into dir: URL) throws -> [String] {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        for r in resources {
            let perTarget = cargoRelease.appendingPathComponent(r.target)
            var isDir: ObjCBool = false
            let src = fm.fileExists(atPath: perTarget.path, isDirectory: &isDir) && !isDir.boolValue ? perTarget : r.source
            let dst = dir.appendingPathComponent(r.target)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src.resolvingSymlinksInPath(), to: dst)
        }
        return resources.map(\.target)
    }

    /// Per-target snapshots → one set (ruling R4, spike B rule): identical files are kept once; files that differ and are
    /// each a thin Mach-O of their own target's architecture are combined into a universal file; any other difference is
    /// a `[build]` error. `snapshots` are (target triple, snapshot dir); every snapshot must hold every target path.
    public static func mergeResources(_ snapshots: [(triple: String, dir: URL)], targets: [String], into dir: URL) throws -> [Resource] {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        var out: [Resource] = []
        for target in targets {
            let copies = snapshots.map { ($0.triple, $0.dir.appendingPathComponent(target)) }
            for (triple, url) in copies where !fm.fileExists(atPath: url.path) {
                throw XlessError(.build, "bundle.resources file '\(target)' is missing after the \(triple) build",
                                 fix: "make the app's build script stage the same bundle.resources files for every target")
            }
            let dst = dir.appendingPathComponent(target)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let datas = try copies.map { try Data(contentsOf: $0.1) }
            if datas.dropFirst().allSatisfy({ $0 == datas[0] }) {
                try fm.copyItem(at: copies[0].1, to: dst)
            } else {
                var slices: [(arch: String, data: Data)] = []
                for ((triple, _), data) in zip(copies, datas) {
                    let want = try TauriMacEnvironment.arch(of: triple)
                    guard !MachO.isFat(data), let archs = try? MachO.sliceArchitectures(in: data), archs.map(\.name) == [want] else {
                        throw XlessError(.build, "bundle.resources file '\(target)' differs between \(copies.map(\.0).joined(separator: " and ")) and the \(triple) copy is not a thin \(want) Mach-O, so the copies cannot be merged",
                                         fix: "make the app's build script stage one file for every target, or one Mach-O per target")
                    }
                    slices.append((want, data))
                }
                // x86_64 first: the order of `lipo -create` output (`lipo -archs` → "x86_64 arm64").
                try MachO.makeFat(slices.sorted { $0.arch > $1.arch }.map(\.data)).write(to: dst)
                let mode = (try? fm.attributesOfItem(atPath: copies[0].1.path)[.posixPermissions]) as? Int ?? 0o644
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dst.path)
            }
            out.append((dst, target))
        }
        return out
    }

    // MARK: assemble

    /// `<Product>.app` in `appDir`: the universal executable, Info.plist, the icon, `resources` (default: the
    /// `bundle.resources` mappings of the work copy's Tauri dir) and `bundle.macOS.frameworks` (`.framework` dirs and
    /// `.dylib` files, relative to the Tauri dir; frameworks whose binary is a static archive are linked, not embedded).
    public static func assemble(resolved r: ResolvedTauriMac, workRoot: URL, universalExecutable: URL, resources: [Resource]? = nil,
                                into appDir: URL, note: (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let tauriDir = workRoot.appendingPathComponent(r.tauriDir)
        let bundle = r.tauri.raw["bundle"] as? [String: Any] ?? [:]
        let mac = bundle["macOS"] as? [String: Any] ?? [:]
        for (key, present) in [("bundle.externalBin", bundle["externalBin"] != nil), ("bundle.macOS.files", mac["files"] != nil)] where present {
            throw XlessError(.build, "\(key) is not supported by xless's macOS bundler", fix: "remove \(key) from tauri.conf.json (or tauri.macos.conf.json)")
        }
        guard let icon = iconFile(bundle) else {
            throw XlessError(.build, "bundle.icon in tauri.conf.json lists no .icns file", fix: "add the .icns icon (e.g. icons/icon.icns from `tauri icon`) to bundle.icon")
        }
        let iconURL = icon.hasPrefix("/") ? URL(fileURLWithPath: icon) : tauriDir.appendingPathComponent(icon)
        guard fm.fileExists(atPath: iconURL.path) else {
            throw XlessError(.build, "bundle.icon \(icon) does not exist (\(iconURL.path))", fix: "fix bundle.icon in tauri.conf.json or run `tauri icon`")
        }
        let info = try infoPlist(resolved: r, workRoot: workRoot)
        let product = try r.config.platform(.macos).product
        let app = appDir.appendingPathComponent("\(product).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resourcesDir = contents.appendingPathComponent("Resources", isDirectory: true)
        for d in ["MacOS", "Resources"] { try fm.createDirectory(at: contents.appendingPathComponent(d), withIntermediateDirectories: true) }

        try fm.copyItem(at: iconURL, to: resourcesDir.appendingPathComponent(iconURL.lastPathComponent))
        try Plist.write(info, to: contents.appendingPathComponent("Info.plist"), format: .xml, stage: .build)

        for framework in mac["frameworks"] as? [String] ?? [] {
            let src = framework.hasPrefix("/") ? URL(fileURLWithPath: framework) : tauriDir.appendingPathComponent(framework)
            guard framework.hasSuffix(".framework") || framework.hasSuffix(".dylib") else {
                throw XlessError(.build, "bundle.macOS.frameworks entry '\(framework)' is not a .framework or .dylib path",
                                 fix: "name the framework by its path (system-wide framework lookup is not available on Linux)")
            }
            guard fm.fileExists(atPath: src.path) else {
                throw XlessError(.build, "bundle.macOS.frameworks entry '\(framework)' does not exist (\(src.path))", fix: "fix bundle.macOS.frameworks in tauri.conf.json")
            }
            if framework.hasSuffix(".framework") {
                let binary = src.appendingPathComponent(src.deletingPathExtension().lastPathComponent).resolvingSymlinksInPath()
                if let data = try? Data(contentsOf: binary), !(try MachO.containsLoadableImage(data)) {
                    note("note: \(src.lastPathComponent) is a static library; linked, not embedded")
                    continue
                }
            }
            let dst = contents.appendingPathComponent("Frameworks/\(src.lastPathComponent)")
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }

        for res in try resources ?? resourceMappings(resources: bundle["resources"], tauriDir: tauriDir) {
            let dst = resourcesDir.appendingPathComponent(res.target)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: res.source.resolvingSymlinksInPath(), to: dst)
        }

        let exe = contents.appendingPathComponent("MacOS/\(info["CFBundleExecutable"] as! String)")
        try fm.copyItem(at: universalExecutable, to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return app
    }
}
