import Testing
import Foundation
@testable import XlessXcode
@testable import XlessCore

// MARK: OpenStep plist

@Test func parsesOpenStepSyntax() throws {
    let text = """
    // !$*UTF8*$!
    {
    \t/* comment */ a = 1;
    \tb = "two \\"quoted\\"\\n\\U00e9 é";
    \tc = (x, "y z", );
    \td = { e = (); f = {}; };
    \t"g h" = "$(inherited)";
    \tpath = "<group>";
    }
    """
    let v = try OpenStepPlist.parse(Data(text.utf8), file: "t.pbxproj")
    let d = try #require(v.dict)
    #expect(d["a"] == .string("1"))
    #expect(d["b"] == .string("two \"quoted\"\né é"))
    #expect(d["c"] == .array([.string("x"), .string("y z")]))
    #expect(d["d"] == .dict(["e": .array([]), "f": .dict([:])]))
    #expect(d["g h"] == .string("$(inherited)"))
    #expect(d["path"] == .string("<group>"))
}

@Test func openStepErrorsCarryLine() {
    let text = "{\n a = 1;\n b = ;\n}"
    #expect {
        _ = try OpenStepPlist.parse(Data(text.utf8), file: "x.pbxproj")
    } throws: { e in
        "\(e)".contains("[prepare] cannot parse x.pbxproj at line 3")
    }
    #expect(throws: XlessError.self) { _ = try OpenStepPlist.parse(Data("{ a = <0a0b>; }".utf8), file: "x") }
    // Unquoted $(…) is not valid OpenStep (CocoaPods refuses it too; contract doc, "Procedure").
    #expect(throws: XlessError.self) { _ = try OpenStepPlist.parse(Data("{ a = $(TEAM); }".utf8), file: "x") }
    #expect(throws: XlessError.self) { _ = try OpenStepPlist.parse(Data("{ a = \"open".utf8), file: "x") }
}

// MARK: Project model

let helloPIF = repoRoot.appendingPathComponent("samples/HelloPIF/HelloPIF.xcodeproj")

@Test func loadsHelloPIF() throws {
    let p = try XcodeProject.load(helloPIF)
    #expect(p.name == "HelloPIF" && p.directory.lastPathComponent == "HelloPIF")
    #expect(p.targets.map(\.name) == ["HelloCore", "HelloKit", "HelloPIF"])
    #expect(p.defaultConfigurationName == "Debug" && p.knownRegions == ["Base", "en"])
    let app = try #require(p.target(named: "HelloPIF"))
    #expect(app.productType == "com.apple.product-type.application")
    #expect(app.dependencies.map(\.location) == [.local(targetID: "3155479B0592C1813219BAF3"), .local(targetID: "CF585561570766755BB641E4")])
    let release = try #require(app.configurations.first { $0.name == "Release" })
    #expect(release.settings["OTHER_LDFLAGS"] == "$(inherited) -ObjC -lc++ -ObjC")
    let script = try #require(app.phases.first { $0.name == "Write build stamp" })
    guard case .shellScript(let s) = script.kind else { Issue.record("not a script phase"); return }
    #expect(s.outputPaths == ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/build-stamp.txt"])
    #expect(s.shellPath == "/bin/sh" && s.showEnvVarsInLog && !s.alwaysOutOfDate)
    let embed = try #require(app.phases.first { $0.name == "Embed Frameworks" })
    #expect(embed.kind == .copyFiles(destinationSubfolder: "$(FRAMEWORKS_FOLDER_PATH)", destinationSubpath: ""))
    #expect(embed.files.first?.attributes == ["CodeSignOnCopy", "RemoveHeadersOnCopy"])
    let core = try #require(p.target(named: "HelloCore"))
    #expect(core.phases.first?.kind == .copyFiles(destinationSubfolder: "<builtProductsDir>", destinationSubpath: "include/$(PRODUCT_NAME)"))
}

@Test func loadsCocoaPodsStyleWorkspace() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("PodsStyle/PodsStyle.xcworkspace"))
    #expect(ws.name == "PodsStyle" && ws.projects.map(\.name) == ["App", "Pods"])
    let app = try #require(ws.projects[0].target(named: "App"))
    #expect(app.dependencies.isEmpty)  // like CocoaPods/Expo: ordered by implicit dependencies only
    // xcconfig base configurations (CocoaPods' Target Support Files)
    let base = try #require(app.configurations.first { $0.name == "Release" }?.baseConfigurationID)
    #expect(ws.projects[0].fileReferences[base]?.path == "Pods-App.release.xcconfig")
    #expect(ws.projects[0].resolvedPath(of: base)?.path.hasSuffix("PodsStyle/Pods/Target Support Files/Pods-App/Pods-App.release.xcconfig") == true)
    let pods = ws.projects[1]
    let lib = try #require(pods.target(named: "CoreLib"))
    let headers = try #require(lib.phases.first { $0.kind == .headers })
    #expect(headers.files.map(\.attributes) == [["Public"], ["Project"]])
    let sources = try #require(lib.phases.first { $0.kind == .sources })
    #expect(sources.files.first?.compilerFlags == "-DCORELIB_FLAG=1 -Wno-comma")
    #expect(pods.target(named: "Vendored")?.kind == .aggregate)
    #expect(pods.target(named: "Pods-App")?.dependencies.count == 3)
    let appPhase = try #require(app.phases.first { $0.name == "[CP] Copy Pods Resources" })
    guard case .shellScript(let s) = appPhase.kind else { Issue.record("not a script phase"); return }
    #expect(s.alwaysOutOfDate && !s.showEnvVarsInLog)
    #expect(s.inputFileListPaths == ["${PODS_ROOT}/Target Support Files/Pods-App/Pods-App-resources-input-files.xcfilelist"])
}

@Test func loadsExpoAppProject() throws {
    let p = try XcodeProject.load(fixturesDir.appendingPathComponent("HelloRN/HelloRN.xcodeproj"))
    let app = try #require(p.target(named: "HelloRN"))
    #expect(app.dependencies.isEmpty)
    let plugins = try #require(app.phases.first { if case .copyFiles = $0.kind { true } else { false } })
    #expect(plugins.kind == .copyFiles(destinationSubfolder: "$(PLUGINS_FOLDER_PATH)", destinationSubpath: ""))
    guard case .reference(let appex) = plugins.files.first?.item else { Issue.record("no appex build file"); return }
    #expect(p.producingTarget(ofProduct: appex)?.name == "HelloExtension")
    // The `xcode` npm package writes explicitFileType = undefined / lastKnownFileType = unknown.
    #expect(p.fileReferences.values.first { $0.path == "HelloExtension.entitlements" }?.fileType == "text.plist.entitlements")
    #expect(p.fileReferences.values.first { $0.path == "ActionViewController.swift" }?.fileType == "sourcecode.swift")
    // libPods-HelloRN.a: a BUILT_PRODUCTS_DIR file, produced by a target of another project.
    let frameworks = try #require(app.phases.first { $0.kind == .frameworks })
    guard case .reference(let lib) = frameworks.files.first?.item else { Issue.record("no library build file"); return }
    #expect(p.fileReferences[lib]?.sourceTree == "BUILT_PRODUCTS_DIR" && p.producingTarget(ofProduct: lib) == nil)
}

@Test func loadsPackageReferencesAndProjectReferences() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("ExtPkg/ExtPkg.xcworkspace"))
    let p = ws.projects[0]
    #expect(p.packageReferences.count == 1)
    let ref = p.packageReferences[0]
    #expect(ref.identity == "greetingkit")
    #expect(ref.kind == .remote(url: "https://example.com/swift/GreetingKit.git",
                                requirement: ["kind": "revision", "revision": "83cca1bb83e4f45fe6dc0d8d6c52c5f656c51051"]))
    let share = try #require(p.target(named: "Share"))
    #expect(share.packageProducts.map(\.productName) == ["GreetingKit"])
    let app = try #require(p.target(named: "ExtPkg"))
    let kit = try #require(app.dependencies.first { $0.name == "Kit" })
    #expect(ws.resolve(kit, in: p)?.target.name == "Kit")
    #expect(p.mainGroup.children.contains { if case .group(let g) = $0 { g.children.contains { if case .group(let v) = $0 { v.isVariantGroup } else { false } } } else { false } })
}

// MARK: Schemes and build requests

@Test func resolvesSchemeBuildTargets() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("HelloRN/HelloRN.xcodeproj"))
    let scheme = try ws.scheme(named: "HelloRN")
    #expect(scheme.buildImplicitDependencies && scheme.parallelizeBuildables)
    #expect(scheme.archiveConfiguration == "Release" && scheme.launchConfiguration == "Debug")
    // The test action names a HelloRNTests target that does not exist; only the build action matters.
    let targets = try ws.buildTargets(of: scheme)
    #expect(targets.map(\.target.name) == ["HelloRN"])
    #expect(throws: XlessError.self) { _ = try ws.scheme(named: "Nope") }
}

@Test func schemeEntryForMissingTargetIsRefused() throws {
    let dir = try copyFixture("PodsStyle")
    let scheme = dir.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme")
    let text = try String(contentsOf: scheme, encoding: .utf8).replacingOccurrences(of: "BlueprintName = \"App\"", with: "BlueprintName = \"Gone\"")
        .replacingOccurrences(of: "443E9F32F0EC65EEBF466F3B", with: "000000000000000000000000")
    try text.write(to: scheme, atomically: true, encoding: .utf8)
    let ws = try XcodeWorkspace.load(dir.appendingPathComponent("PodsStyle.xcworkspace"))
    #expect {
        _ = try ws.buildTargets(of: ws.scheme(named: "App"))
    } throws: { e in
        "\(e)".contains("scheme App builds Gone (000000000000000000000000), which is not a target of App")
    }
}

@Test func buildRequestTurnsOnImplicitDependencies() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("PodsStyle/PodsStyle.xcworkspace"))
    let data = try BuildRequest.make(workspace: ws, scheme: ws.scheme(named: "App"), configuration: "Release",
                                     overrides: ["CODE_SIGNING_ALLOWED": "NO"])
    let r = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(r["useImplicitDependencies"] as? Bool == true)
    #expect(r["dependencyScope"] as? String == "workspace")
    let params = try #require(r["parameters"] as? [String: Any])
    #expect(params["action"] as? String == "build" && params["configurationName"] as? String == "Release")
    let table = ((params["overrides"] as? [String: Any])?["commandLine"] as? [String: Any])?["table"] as? [String: String]
    #expect(table == ["CODE_SIGNING_ALLOWED": "NO"])
    let dest = try #require(params["activeRunDestination"] as? [String: Any])
    #expect(dest["platform"] as? String == "iphoneos" && dest["targetArchitecture"] as? String == "arm64")
    let targets = try #require(r["configuredTargets"] as? [[String: String]])
    let app = try #require(ws.projects[0].target(named: "App"))
    #expect(targets == [["guid": PIFWriter.targetGUID(app, in: ws.projects[0], workspace: ws)]])
    for key in ["useParallelTargets", "useDryRun", "continueBuildingAfterErrors", "hideShellScriptEnvironment",
                "showNonLoggedProgress", "enableIndexBuildArena", "useLegacyBuildLocations", "buildCommand"] {
        #expect(r[key] != nil, "missing \(key)")
    }
}

// MARK: PIF

@Test func pifIsDeterministicAndSignaturesTrackContents() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("PodsStyle/PodsStyle.xcworkspace"))
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("xless-pif-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let a = try Data(contentsOf: PIFWriter.write(ws, to: out.appendingPathComponent("a")))
    let b = try Data(contentsOf: PIFWriter.write(ws, to: out.appendingPathComponent("b")))
    #expect(a == b)
    let url = try PIFWriter.write(ws, to: out)
    #expect(url.lastPathComponent == "PodsStyle.pif")
    let objects = try PIFNormaliser.load(url)
    #expect(objects.first?["type"]?.stringValue == "workspace")
    #expect(objects.compactMap { $0["signature"]?.stringValue }.count == Set(objects.compactMap { $0["signature"]?.stringValue }).count)

    let dir = try copyFixture("PodsStyle")
    let pbx = dir.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj")
    try String(contentsOf: pbx, encoding: .utf8).replacingOccurrences(of: "-DCORELIB_FLAG=1", with: "-DCORELIB_FLAG=2")
        .write(to: pbx, atomically: true, encoding: .utf8)
    let changed = try PIFWriter.objects(XcodeWorkspace.load(dir.appendingPathComponent("PodsStyle.xcworkspace")))
    let sigs = { (o: [JSON]) in Set(o.compactMap { $0["contents"]?["name"]?.stringValue == "CoreLib" ? $0["signature"]?.stringValue : nil }) }
    #expect(sigs(changed) != sigs(objects) && !sigs(changed).isEmpty)
}

@Test func unresolvedSwiftPackageIsRefused() throws {
    let ws = try XcodeWorkspace.load(fixturesDir.appendingPathComponent("ExtPkg/ExtPkg.xcworkspace"))
    #expect {
        _ = try PIFWriter.objects(ws)
    } throws: { e in
        "\(e)".hasPrefix("[prepare] Swift package product GreetingKit (https://example.com/swift/GreetingKit.git @ kind=revision,revision=83cca1bb83e4f45fe6dc0d8d6c52c5f656c51051) used by target Share is not resolved")
    }
    let package = try ResolvedPackage(identity: "greetingkit",
                                      dumpPIF: Data(contentsOf: fixturesDir.appendingPathComponent("ExtPkg/GreetingKit.dump-pif.json")))
    let objects = try PIFWriter.objects(ws, packages: [package])
    let projects = objects.first?["contents"]?["projects"]?.arrayValue ?? []
    #expect(projects.count == 3)  // ExtPkg, Kit, and the package
    #expect(package.projects.count == 1 && package.projects[0].targets.count == 4)
    #expect(throws: XlessError.self) {
        _ = try ResolvedPackage(identity: "other", dumpPIF: Data(contentsOf: fixturesDir.appendingPathComponent("ExtPkg/GreetingKit.dump-pif.json")))
    }
    #expect(objects.contains { $0["contents"]?["guid"]?.stringValue == "PACKAGE-PRODUCT:greetingkit_GreetingKit.GreetingKit" })
}

// MARK: Refusals

func copyFixture(_ name: String, from base: URL = fixturesDir) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-xcode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: base.appendingPathComponent(name), to: dir.appendingPathComponent(name))
    return dir.appendingPathComponent(name)
}

/// HelloPIF's project with `edit` applied to its pbxproj text.
func helloPIFProject(_ edit: (String) -> String) throws -> URL {
    let dir = try copyFixture("HelloPIF", from: repoRoot.appendingPathComponent("samples"))
    let pbx = dir.appendingPathComponent("HelloPIF.xcodeproj/project.pbxproj")
    let text = try String(contentsOf: pbx, encoding: .utf8)
    let edited = edit(text)
    #expect(edited != text, "edit did not apply")
    try edited.write(to: pbx, atomically: true, encoding: .utf8)
    return dir.appendingPathComponent("HelloPIF.xcodeproj")
}

struct Refusal: CustomTestStringConvertible, Sendable {
    let name: String
    let edit: @Sendable (String) -> String
    let message: String
    var testDescription: String { name }

    static let all = [
        Refusal(name: "build rule", edit: {
            $0.replacingOccurrences(of: "\t\t3155479B0592C1813219BAF3 /* HelloCore */ = {\n\t\t\tisa = PBXNativeTarget;",
                                    with: "\t\tAAAAAAAAAAAAAAAAAAAAAAAA = {isa = PBXBuildRule; compilerSpec = com.apple.compilers.proxy.script; };\n\t\t3155479B0592C1813219BAF3 /* HelloCore */ = {\n\t\t\tisa = PBXNativeTarget;")
                .replacingOccurrences(of: "buildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = HelloCore;",
                                      with: "buildRules = (\n\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA,\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = HelloCore;")
        }, message: "[prepare] unsupported pbxproj PBXNativeTarget buildRules (PBXBuildRule) at 3155479B0592C1813219BAF3 in "),
        Refusal(name: "synchronized folder", edit: {
            $0.replacingOccurrences(of: "\t\t\t\t459DE639D8BA7ECAE1225AB8 /* App */,\n",
                                    with: "\t\t\t\t459DE639D8BA7ECAE1225AB8 /* App */,\n\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB,\n")
                .replacingOccurrences(of: "/* Begin PBXGroup section */",
                                      with: "\t\tBBBBBBBBBBBBBBBBBBBBBBBB = {isa = PBXFileSystemSynchronizedRootGroup; path = Extra; sourceTree = \"<group>\"; };\n/* Begin PBXGroup section */")
        }, message: "[prepare] unsupported pbxproj PBXFileSystemSynchronizedRootGroup at BBBBBBBBBBBBBBBBBBBBBBBB in "),
        Refusal(name: "unknown key", edit: {
            $0.replacingOccurrences(of: "isa = PBXFileReference; lastKnownFileType = text; path = greeting.txt;",
                                    with: "isa = PBXFileReference; lastKnownFileType = text; platformFilter = ios; path = greeting.txt;")
        }, message: "[prepare] unsupported pbxproj PBXFileReference key platformFilter at 2422D2B54907CDAD57C27148 in "),
        Refusal(name: "copy destination", edit: {
            $0.replacingOccurrences(of: "dstSubfolderSpec = 10;", with: "dstSubfolderSpec = 14;")
        }, message: "[prepare] unsupported pbxproj dstSubfolderSpec 14 at 925F1D828344C16B24195327 in "),
        Refusal(name: "build file setting", edit: {
            $0.replacingOccurrences(of: "settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); };",
                                    with: "settings = {ASSET_TAGS = (a, ); };")
        }, message: "[prepare] unsupported pbxproj PBXBuildFile settings key ASSET_TAGS at C509500887460B7FA77ECD41 in "),
        Refusal(name: "product type", edit: {
            $0.replacingOccurrences(of: "productType = \"com.apple.product-type.framework\";",
                                    with: "productType = \"com.apple.product-type.watchkit2-extension\";")
        }, message: "[prepare] unsupported pbxproj productType com.apple.product-type.watchkit2-extension at CF585561570766755BB641E4 in "),
        Refusal(name: "source tree", edit: {
            $0.replacingOccurrences(of: "path = greeting.txt; sourceTree = \"<group>\";", with: "path = greeting.txt; sourceTree = MY_ROOT;")
        }, message: "[prepare] unsupported pbxproj sourceTree MY_ROOT at 2422D2B54907CDAD57C27148 in "),
    ]
}

@Test(arguments: Refusal.all)
func refusesOutsideTheSubset(_ r: Refusal) throws {
    let project = try helloPIFProject(r.edit)
    #expect {
        _ = try XcodeProject.load(project)
    } throws: { e in
        let s = "\(e)"
        return s.hasPrefix(r.message) && s.contains("project.pbxproj — xless builds the project subset")
    }
}

@Test func workspaceLocationsAndGroups() throws {
    let dir = try copyFixture("PodsStyle")
    let contents = dir.appendingPathComponent("PodsStyle.xcworkspace/contents.xcworkspacedata")
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace version = "1.0">
       <Group location = "container:Pods" name = "Pods">
          <FileRef location = "group:Pods.xcodeproj"></FileRef>
       </Group>
       <FileRef location = "container:App.xcodeproj"></FileRef>
       <FileRef location = "group:Podfile.lock"></FileRef>
    </Workspace>
    """.write(to: contents, atomically: true, encoding: .utf8)
    let ws = try XcodeWorkspace.load(dir.appendingPathComponent("PodsStyle.xcworkspace"))
    #expect(ws.projects.map(\.name) == ["Pods", "App"])
    try "<Workspace><FileRef location = \"developer:Foo.xcodeproj\"/></Workspace>".write(to: contents, atomically: true, encoding: .utf8)
    #expect(throws: XlessError.self) { _ = try XcodeWorkspace.load(dir.appendingPathComponent("PodsStyle.xcworkspace")) }
}

/// A file reference no group contains (an Expo config plugin can add one): Xcode's PIF lists it in a synthetic
/// "Recovered References" group at the end of the main group, path relative to the project directory
/// (checked against `xcodebuild -dumpPIF` of this edit).
@Test func orphanFileReferencesGoToRecoveredReferences() throws {
    let project = try helloPIFProject {
        $0.replacingOccurrences(of: "\t\t\t\t2422D2B54907CDAD57C27148 /* greeting.txt */,\n", with: "")
            .replacingOccurrences(of: "lastKnownFileType = text; path = greeting.txt;", with: "lastKnownFileType = text; name = greeting.txt; path = App/greeting.txt;")
    }
    let ws = try XcodeWorkspace.load(project)
    #expect(ws.projects[0].recoveredReferenceIDs == ["2422D2B54907CDAD57C27148"])
    #expect(ws.projects[0].resolvedPath(of: "2422D2B54907CDAD57C27148")?.path.hasSuffix("HelloPIF/App/greeting.txt") == true)
    let objects = try PIFWriter.objects(ws)
    let tree = try #require(objects.first { $0["type"]?.stringValue == "project" }?["contents"]?["groupTree"]?["children"]?.arrayValue)
    let recovered = try #require(tree.last)
    #expect(recovered["name"]?.stringValue == "Recovered References" && recovered["path"]?.stringValue == "")
    let file = try #require(recovered["children"]?.arrayValue?.first)
    #expect(file["path"]?.stringValue == "App/greeting.txt" && file["sourceTree"]?.stringValue == "<group>")
}
