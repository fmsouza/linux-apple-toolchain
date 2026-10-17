import Foundation
import XlessCore

/// Writes a `Workspace` as a Swift Build PIF: the JSON array of `{type, signature, contents}` objects that
/// `xcodebuild -dumpPIF` writes and `swbuild` loads (`.pif`/`.json` containers). Field names follow swift-build's
/// `SWBCore/ProjectModel` loaders; values follow how Xcode maps pbxproj objects (docs/research/react-native-ios-contract.md,
/// "XlessXcode: pbxproj → PIF").
///
/// GUIDs are stable: a project's GUID hashes its path relative to the workspace, every object's GUID is the project
/// GUID plus the pbxproj object ID. Signatures are `<TYPE>@<guid>-<hash of the contents>`, so a changed object gets a
/// new signature and Swift Build never reuses a stale cached copy.
public enum PIFWriter {
    /// Writes `<dir>/<workspace name>.pif` and returns its URL.
    @discardableResult
    public static func write(_ workspace: Workspace, to dir: URL, packages: [ResolvedPackage] = []) throws -> URL {
        let objects = try self.objects(workspace, packages: packages)
        let text = JSON.array(objects).serialized()
        let url = dir.appendingPathComponent("\(workspace.name).pif")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw XlessError(.prepare, "cannot write \(url.path): \(error.localizedDescription)", fix: "check the output directory")
        }
        return url
    }

    /// The PIF objects, workspace first, then each project followed by its targets.
    public static func objects(_ workspace: Workspace, packages: [ResolvedPackage] = []) throws -> [JSON] {
        var b = Builder(ws: workspace, packages: packages)
        return try b.build()
    }

    public static func projectGUID(_ project: XcodeProject, in workspace: Workspace) -> String {
        let container = workspace.containerDirectory.path
        var rel = project.path.path
        if rel.hasPrefix(container + "/") { rel.removeFirst(container.count + 1) }
        return "P" + FNV.hash(rel)
    }

    public static func targetGUID(_ target: Target, in project: XcodeProject, workspace: Workspace) -> String {
        projectGUID(project, in: workspace) + ":" + target.id
    }

    static func signature(_ type: String, _ contents: JSON) -> String {
        let guid = contents["guid"]?.stringValue ?? ""
        return "\(type)@\(guid)-\(FNV.hash(contents.serialized()))"
    }
}

extension Workspace {
    /// The directory `container:` locations and project GUIDs are relative to.
    var containerDirectory: URL {
        path.lastPathComponent == "project.xcworkspace"
            ? path.deletingLastPathComponent().deletingLastPathComponent() : path.deletingLastPathComponent()
    }
}

/// A Swift package's PIF, for `XCSwiftPackageProductDependency`s: what `swift package --build-system swiftbuild
/// dump-pif` writes in the resolved package checkout. SwiftPM names the package's project `PACKAGE:<identity>` after
/// the checkout directory, so the checkout must be named by the package identity. Each package it depends on is
/// another `PACKAGE:` project; all are kept (the `AGGREGATE` project and the workspace are not).
public struct ResolvedPackage: Sendable {
    public let identity: String
    /// Package projects, each followed by its targets: the root package first, then its dependencies.
    public let projects: [(project: JSON, targets: [JSON])]

    public init(identity: String, dumpPIF data: Data) throws {
        self.identity = identity.lowercased()
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch {
            throw XlessError(.prepare, "the PIF of Swift package \(identity) is not JSON: \(error.localizedDescription)",
                             fix: "regenerate it with swift package --build-system swiftbuild dump-pif")
        }
        guard case .array(let all) = try JSON(foundation: parsed) else {
            throw XlessError(.prepare, "the PIF of Swift package \(identity) is not an array", fix: "regenerate it with swift package dump-pif")
        }
        var targetsBySignature: [String: JSON] = [:]
        for o in all where o["type"]?.stringValue == "target" {
            if let s = o["signature"]?.stringValue { targetsBySignature[s] = o }
        }
        let rootGUID = "PACKAGE:\(self.identity)"
        var projects: [(JSON, [JSON])] = []
        for o in all where o["type"]?.stringValue == "project" {
            guard let guid = o["contents"]?["guid"]?.stringValue, guid.hasPrefix("PACKAGE:") else { continue }
            let targets = (o["contents"]?["targets"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { targetsBySignature[$0] } }
            if guid == rootGUID { projects.insert((o, targets), at: 0) } else { projects.append((o, targets)) }
        }
        guard projects.first?.0["contents"]?["guid"]?.stringValue == rootGUID else {
            throw XlessError(.prepare, "the PIF of Swift package \(identity) has no project \(rootGUID)",
                             fix: "dump the PIF in a checkout directory named after the package identity (\(self.identity))")
        }
        self.projects = projects
    }

    /// The GUID of the target that builds `product` (SwiftPM names it `<product>-product`), in the root package first.
    func productGUID(_ product: String) -> String? {
        for (_, targets) in projects {
            for o in targets {
                guard let c = o["contents"], let guid = c["guid"]?.stringValue, guid.hasPrefix("PACKAGE-PRODUCT:"),
                      c["name"]?.stringValue == "\(product)-product" else { continue }
                return guid
            }
        }
        return nil
    }
}

private struct Builder {
    let ws: Workspace
    let packages: [ResolvedPackage]
    var plistCache: [String: String] = [:]
    /// Per project path: IDs in the PIF group tree.
    let treeIDs: [String: Set<String>]

    init(ws: Workspace, packages: [ResolvedPackage]) {
        self.ws = ws
        self.packages = packages
        var ids: [String: Set<String>] = [:]
        for p in ws.projects { ids[p.path.path] = Self.groupTreeIDs(p) }
        treeIDs = ids
    }

    func groupTreeIDs(_ p: XcodeProject) -> Set<String> { treeIDs[p.path.path] ?? [] }

    func objectGUID(_ project: XcodeProject, _ id: String) -> String { PIFWriter.projectGUID(project, in: ws) + ":" + id }

    func refuse(_ what: String, _ project: XcodeProject) -> XlessError {
        XlessError(.prepare, "unsupported pbxproj \(what) in \(project.path.appendingPathComponent("project.pbxproj").path)",
                   fix: "xless builds the project subset that React Native, Expo and CocoaPods generate; build this project on a Mac")
    }

    mutating func build() throws -> [JSON] {
        var out: [JSON] = []
        var projectSignatures: [String] = []
        for project in ws.projects {
            var targetObjects: [JSON] = []
            for target in project.targets {
                let contents = try targetContents(target, project)
                targetObjects.append(.object(["type": .string("target"), "signature": .string(PIFWriter.signature("TARGET", contents)),
                                              "contents": contents]))
            }
            let contents = try projectContents(project, targetSignatures: targetObjects.map { $0["signature"]!.stringValue! })
            let sig = PIFWriter.signature("PROJECT", contents)
            projectSignatures.append(sig)
            out.append(.object(["type": .string("project"), "signature": .string(sig), "contents": contents]))
            out += targetObjects
        }
        // Package projects, each once (packages share dependencies).
        var seen = Set<String>()
        for package in usedPackages() {
            for (project, targets) in package.projects {
                guard let guid = project["contents"]?["guid"]?.stringValue, seen.insert(guid).inserted,
                      let sig = project["signature"]?.stringValue else { continue }
                projectSignatures.append(sig)
                out += [project] + targets
            }
        }
        let contents = JSON.object([
            "guid": .string("W" + FNV.hash(ws.path.lastPathComponent)),
            "name": .string(ws.name),
            "path": .string(ws.path.path),
            "projects": .array(projectSignatures.map(JSON.string)),
        ])
        return [.object(["type": .string("workspace"), "signature": .string(PIFWriter.signature("WORKSPACE", contents)),
                         "contents": contents])] + out
    }

    /// Packages that some target uses, in workspace order.
    func usedPackages() -> [ResolvedPackage] {
        var used: [ResolvedPackage] = []
        for project in ws.projects {
            for ref in project.packageReferences {
                if let p = packages.first(where: { $0.identity == ref.identity }), !used.contains(where: { $0.identity == p.identity }) {
                    used.append(p)
                }
            }
        }
        return used
    }

    // MARK: project

    func projectContents(_ p: XcodeProject, targetSignatures: [String]) throws -> JSON {
        var c: [String: JSON] = [
            "appPreferencesBuildSettings": .object([:]),
            "buildConfigurations": .array(try p.configurations.map { try configuration($0, p) }),
            "classPrefix": .string(""),
            "defaultConfigurationName": .string(p.defaultConfigurationName),
            "groupTree": try group(p.mainGroup, p, isMain: true),
            "guid": .string(PIFWriter.projectGUID(p, in: ws)),
            "knownRegions": .array(p.knownRegions.map(JSON.string)),
            "path": .string(p.path.path),
            "projectDirectory": .string(p.directory.path),
            "targets": .array(targetSignatures.map(JSON.string)),
        ]
        if let region = p.developmentRegion { c["developmentRegion"] = .string(region) }
        return .object(c)
    }

    func configuration(_ c: BuildConfiguration, _ p: XcodeProject) throws -> JSON {
        var o: [String: JSON] = [
            "guid": .string(objectGUID(p, c.id)),
            "name": .string(c.name),
            "buildSettings": .object(c.settings.mapValues(JSON.string)),
        ]
        if let base = c.baseConfigurationID {
            guard groupTreeIDs(p).contains(base) else {
                throw refuse("baseConfigurationReference \(base) of configuration \(c.name) (\(c.id)): not in the project's group tree", p)
            }
            o["baseConfigurationFileReference"] = .string(objectGUID(p, base))
        }
        return .object(o)
    }

    /// IDs of the file references and groups that appear in the PIF group tree (products of this project's own
    /// targets are left out, as Xcode does).
    static func groupTreeIDs(_ p: XcodeProject) -> Set<String> {
        var ids = Set<String>()
        let products = Set(p.targets.compactMap(\.productReferenceID))
        func walk(_ g: Group) {
            ids.insert(g.id)
            for child in g.children {
                switch child {
                case .group(let sub): walk(sub)
                case .file(let f) where !products.contains(f.id): ids.insert(f.id)
                case .file: continue
                }
            }
        }
        walk(p.mainGroup)
        ids.formUnion(p.recoveredReferenceIDs)
        return ids
    }

    func group(_ g: Group, _ p: XcodeProject, isMain: Bool = false) throws -> JSON {
        let products = Set(p.targets.compactMap(\.productReferenceID))
        var children: [JSON] = []
        for child in g.children {
            switch child {
            case .group(let sub): children.append(try group(sub, p))
            case .file(let f) where products.contains(f.id): continue
            case .file(let f): children.append(file(f, p, region: g.isVariantGroup ? f.name ?? Self.region(of: f.path) : nil))
            }
        }
        if isMain, !p.recoveredReferenceIDs.isEmpty {
            children.append(.object([
                "children": .array(p.recoveredReferenceIDs.compactMap { p.fileReferences[$0] }.map { file($0, p, region: nil) }),
                "guid": .string(objectGUID(p, "RecoveredReferences")),
                "name": .string("Recovered References"),
                "path": .string(""),
                "sourceTree": .string("<group>"),
                "type": .string("group"),
            ]))
        }
        let name = g.name ?? (isMain ? p.name : g.path.map { ($0 as NSString).lastPathComponent } ?? "")
        var o: [String: JSON] = [
            "guid": .string(objectGUID(p, g.id)),
            "name": .string(name),
            "path": .string(g.path ?? ""),
            "sourceTree": .string(g.sourceTree),
            "type": .string(g.isVariantGroup ? "variantGroup" : "group"),
        ]
        if !children.isEmpty { o["children"] = .array(children) }
        return .object(o)
    }

    /// `en` for `en.lproj/Localizable.strings`.
    static func region(of path: String) -> String? {
        path.split(separator: "/").first(where: { $0.hasSuffix(".lproj") }).map { String($0.dropLast(6)) }
    }

    func file(_ f: FileReference, _ p: XcodeProject, region: String?) -> JSON {
        var o: [String: JSON] = [
            "fileType": .string(f.fileType),
            "guid": .string(objectGUID(p, f.id)),
            "path": .string(f.path),
            "sourceTree": .string(f.sourceTree),
            "type": .string("file"),
        ]
        // Xcode writes an encoding only for text and source files (not for storyboards, even when the pbxproj has one).
        if let e = f.textEncoding, f.fileType.hasPrefix("text.") || f.fileType.hasPrefix("sourcecode.") {
            o["fileTextEncoding"] = .string(e)
        }
        if let region { o["regionVariantName"] = .string(region) }
        return .object(o)
    }

    // MARK: target

    mutating func targetContents(_ t: Target, _ p: XcodeProject) throws -> JSON {
        var deps: [JSON] = []
        for d in t.dependencies {
            guard let (dp, dt) = ws.resolve(d, in: p) else {
                throw refuse("PBXTargetDependency \(d.id) of target \(t.name): its target is not in the workspace", p)
            }
            // Xcode names a dependency on another project's target "<target> (from <project>.xcodeproj)".
            let name = dp.path == p.path ? dt.name : "\(dt.name) (from \(dp.path.lastPathComponent))"
            deps.append(.object(["guid": .string(PIFWriter.targetGUID(dt, in: dp, workspace: ws)), "name": .string(name)]))
        }
        for product in t.packageProducts {
            let guid = try packageProductGUID(product, t, p)
            deps.append(.object(["guid": .string(guid), "name": .string(product.productName)]))
        }
        var c: [String: JSON] = [
            "buildConfigurations": .array(try t.configurations.map { try configuration($0, p) }),
            "buildPhases": .array(try t.phases.map { try phase($0, t, p) }),
            "buildRules": .array([]),
            "dependencies": .array(deps),
            "guid": .string(PIFWriter.targetGUID(t, in: p, workspace: ws)),
            "name": .string(t.name),
            "provisioningSourceData": .array(try t.configurations.map { try provisioning($0, t, p) }),
        ]
        switch t.kind {
        case .aggregate:
            c["type"] = .string("aggregate")
        case .native(let productType):
            c["type"] = .string("standard")
            c["productTypeIdentifier"] = .string(productType)
            guard let pr = t.productReferenceID, let product = p.fileReferences[pr] else {
                throw refuse("PBXNativeTarget \(t.id) without productReference", p)
            }
            c["productReference"] = .object(["guid": .string(objectGUID(p, pr)), "name": .string(Self.productName(t, product, p)),
                                             "type": .string("product")])
            if let lang = predominantLanguage(t, p) { c["predominantSourceCodeLanguage"] = .string(lang) }
        }
        return .object(c)
    }

    /// The product file name. Swift Build matches implicit dependencies on it (a `libPods-App.a` build file → the
    /// target whose product is named so), and Xcode writes the evaluated name: a literal `PRODUCT_NAME` of the
    /// default configuration (target, else project level) wins over the pbxproj product path's stem.
    static func productName(_ t: Target, _ product: FileReference, _ p: XcodeProject) -> String {
        let config = t.configurations.first { $0.name == t.defaultConfigurationName } ?? t.configurations.first
        let projectConfig = p.configurations.first { $0.name == config?.name }
        let setting = config?.settings["PRODUCT_NAME"] ?? projectConfig?.settings["PRODUCT_NAME"]
        let name: String
        switch setting {
        case nil, "$(TARGET_NAME)", "${TARGET_NAME}": name = t.name
        case let s? where !s.contains("$"): name = s
        default: return product.path
        }
        let file = (product.path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let prefix = file.hasPrefix("lib") && (ext == "a" || ext == "dylib") ? "lib" : ""
        return prefix + name + (ext.isEmpty ? "" : "." + ext)
    }

    func packageProductGUID(_ product: PackageProductDependency, _ t: Target, _ p: XcodeProject) throws -> String {
        let ref = product.packageID.flatMap { id in p.packageReferences.first { $0.id == id } }
        let identity = ref?.identity
        let described: String
        switch ref?.kind {
        case .remote(let url, let req)?: described = "\(url) @ \(req.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        case .local(let path)?: described = path
        case nil: described = "unknown package"
        }
        guard let identity, let package = packages.first(where: { $0.identity == identity }),
              let guid = package.productGUID(product.productName) else {
            throw XlessError(.prepare, "Swift package product \(product.productName) (\(described)) used by target \(t.name) is not resolved",
                             fix: "resolve the package and pass its PIF (swift package --build-system swiftbuild dump-pif) to the PIF writer")
        }
        return guid
    }

    /// Xcode's `predominantSourceCodeLanguage` (only Core ML / Intents code generation read it): Swift when the
    /// target compiles only Swift, else its most common C-family language.
    func predominantLanguage(_ t: Target, _ p: XcodeProject) -> String? {
        var counts: [String: Int] = [:]
        for phase in t.phases where phase.kind == .sources {
            for f in phase.files {
                guard case .reference(let id) = f.item, let ref = p.fileReferences[id] else { continue }
                let lang: String? = switch ref.fileType {
                case "sourcecode.swift": "Swift"
                case "sourcecode.c.objc": "Objective-C"
                case "sourcecode.cpp.objcpp": "Objective-C-Plus-Plus"
                case "sourcecode.cpp.cpp": "C-Plus-Plus"
                case "sourcecode.c.c": "C"
                default: nil
                }
                if let lang { counts[lang, default: 0] += 1 }
            }
        }
        if counts.isEmpty { return nil }
        let cFamily = counts.filter { $0.key != "Swift" }
        let order = ["Objective-C", "Objective-C-Plus-Plus", "C-Plus-Plus", "C"]
        let pick = cFamily.isEmpty ? "Swift"
            : cFamily.max { a, b in a.value != b.value ? a.value < b.value : order.firstIndex(of: a.key)! > order.firstIndex(of: b.key)! }!.key
        return "Xcode.SourceCodeLanguage.\(pick)"
    }

    /// `provisioningSourceData` for one configuration. Signing is xless's own stage (the build runs with
    /// `CODE_SIGNING_ALLOWED=NO`), so this only mirrors Xcode: manual when the target clears its signing identity or
    /// says so, and the bundle ID from the target's Info.plist.
    mutating func provisioning(_ c: BuildConfiguration, _ t: Target, _ p: XcodeProject) throws -> JSON {
        var manual = p.provisioningStyles[t.id] == "Manual"
        if c.settings["CODE_SIGN_STYLE"] == "Manual" { manual = true }
        if c.settings.contains(where: { ($0.key == "CODE_SIGN_IDENTITY" || $0.key.hasPrefix("CODE_SIGN_IDENTITY[")) && $0.value.isEmpty }) {
            manual = true
        }
        if c.settings["CODE_SIGN_STYLE"] == "Automatic" { manual = false }
        var bundleID = ""
        if let plist = c.settings["INFOPLIST_FILE"], !plist.contains("$") {
            bundleID = infoPlistBundleID(p.directory.appendingPathComponent(plist))
        } else if c.settings["GENERATE_INFOPLIST_FILE"] == "YES" {
            bundleID = "$(PRODUCT_BUNDLE_IDENTIFIER)"
        }
        return .object(["bundleIdentifierFromInfoPlist": .string(bundleID), "configurationName": .string(c.name),
                        "provisioningStyle": .int(manual ? 1 : 0)])
    }

    mutating func infoPlistBundleID(_ url: URL) -> String {
        if let cached = plistCache[url.path] { return cached }
        var id = ""
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let s = plist["CFBundleIdentifier"] as? String {
            id = s
        }
        plistCache[url.path] = id
        return id
    }

    // MARK: phases

    func phase(_ ph: BuildPhase, _ t: Target, _ p: XcodeProject) throws -> JSON {
        var o: [String: JSON] = [
            "guid": .string(objectGUID(p, ph.id)),
            "buildFiles": .array(try ph.files.map { try buildFile($0, ph, t, p) }),
        ]
        switch ph.kind {
        case .sources: o["type"] = .string("com.apple.buildphase.sources")
        case .frameworks: o["type"] = .string("com.apple.buildphase.frameworks")
        case .resources: o["type"] = .string("com.apple.buildphase.resources")
        case .headers: o["type"] = .string("com.apple.buildphase.headers")
        case .copyFiles(let folder, let subpath):
            o["type"] = .string("com.apple.buildphase.copy-files")
            o["destinationSubfolder"] = .string(folder)
            o["destinationSubpath"] = .string(subpath)
        case .shellScript(let s):
            o["type"] = .string("com.apple.buildphase.shell-script")
            o["name"] = .string(ph.name ?? "Run Script")
            o["alwaysOutOfDate"] = .string(s.alwaysOutOfDate ? "true" : "false")
            o["alwaysRunForInstallHdrs"] = .string("false")
            o["emitEnvironment"] = .string(s.showEnvVarsInLog ? "true" : "false")
            o["inputFileListPaths"] = .array(s.inputFileListPaths.map(JSON.string))
            o["inputFilePaths"] = .array(s.inputPaths.map(JSON.string))
            o["outputFileListPaths"] = .array(s.outputFileListPaths.map(JSON.string))
            o["outputFilePaths"] = .array(s.outputPaths.map(JSON.string))
            o["originalObjectID"] = .string(ph.id)
            o["sandboxingOverride"] = .string("basedOnBuildSetting")
            o["scriptContents"] = .string(s.script)
            o["shellPath"] = .string(s.shellPath)
        }
        if ph.runOnlyForDeploymentPostprocessing { o["runOnlyForDeploymentPostprocessing"] = .string("true") }
        return .object(o)
    }

    func buildFile(_ f: BuildFile, _ ph: BuildPhase, _ t: Target, _ p: XcodeProject) throws -> JSON {
        var o: [String: JSON] = ["guid": .string(objectGUID(p, f.id))]
        switch f.item {
        case .packageProduct(let id):
            guard let product = t.packageProducts.first(where: { $0.id == id }) else {
                throw refuse("PBXBuildFile \(f.id): package product \(id) is not one of target \(t.name)'s packageProductDependencies", p)
            }
            o["targetReference"] = .string(try packageProductGUID(product, t, p))
        case .reference(let id):
            if let producer = p.producingTarget(ofProduct: id) {
                o["targetReference"] = .string(PIFWriter.targetGUID(producer, in: p, workspace: ws))
            } else if let proxy = p.referenceProxies[id] {
                guard let url = p.resolvedPath(of: proxy.containerPortalID), let other = ws.project(at: url),
                      let producer = other.producingTarget(ofProduct: proxy.remoteProductID) else {
                    throw refuse("PBXReferenceProxy \(id) (\(proxy.path)): its project or target is not in the workspace", p)
                }
                o["targetReference"] = .string(PIFWriter.targetGUID(producer, in: other, workspace: ws))
            } else {
                guard groupTreeIDs(p).contains(id) else {
                    throw refuse("PBXBuildFile \(f.id): file \(id) is not in the project's group tree", p)
                }
                o["fileReference"] = .string(objectGUID(p, id))
            }
        }
        for a in f.attributes {
            switch a {
            case "CodeSignOnCopy": o["codeSignOnCopy"] = .string("true")
            case "RemoveHeadersOnCopy": o["removeHeadersOnCopy"] = .string("true")
            case "Weak": o["shouldLinkWeakly"] = .string("true")
            case "Public": o["headerVisibility"] = .string("public")
            case "Private": o["headerVisibility"] = .string("private")
            default: continue  // Project, Required: the defaults
            }
        }
        if let flags = f.compilerFlags { o["additionalCompilerOptions"] = .string(flags) }
        return .object(o)
    }
}
