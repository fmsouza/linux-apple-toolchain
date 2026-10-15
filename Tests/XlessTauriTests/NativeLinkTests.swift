import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

@Suite struct NativeLinkTests {
    @Test func expandsSettings() {
        let vars = ["PROJECT_DIR": "/W", "CONFIGURATION": "release", "SDKROOT": "/SDK"]
        #expect(NativeLink.expandSettings("$(inherited) $(PROJECT_DIR)/Externals/arm64/$(CONFIGURATION) $(SDKROOT)/usr/lib/swift", vars: vars)
                == ["/W/Externals/arm64/release", "/SDK/usr/lib/swift"])
        #expect(NativeLink.expandSettings("${PROJECT_DIR}/a \"$(PROJECT_DIR)/b c\" $(UNSET)/d", vars: vars) == ["/W/a", "/W/b c", "/d"])
        #expect(NativeLink.expandSettings("", vars: vars).isEmpty)
    }

    @Test func prefersTheArm64Setting() {
        let settings = ["LIBRARY_SEARCH_PATHS": "plain", "LIBRARY_SEARCH_PATHS[arch=x86_64]": "intel", "LIBRARY_SEARCH_PATHS[arch=arm64]": "arm"]
        #expect(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: settings) == "arm")
        #expect(NativeLink.setting("LIBRARY_SEARCH_PATHS", in: ["LIBRARY_SEARCH_PATHS": "plain"]) == "plain")
        #expect(NativeLink.setting("HEADER_SEARCH_PATHS", in: settings) == nil)
    }

    /// Xcode's CompileC flags for main.mm minus header maps, -g/-gmodules and diagnostics plumbing (contract, spike A step 7).
    @Test func compileArgumentsForObjectiveCPlusPlus() {
        let args = NativeLink.compileArguments(source: "/W/Sources/app/main.mm", object: "/W/.xless/obj/main.o", headerSearchPaths: ["/W/include"],
                                               minOS: "16.0", sdk: URL(fileURLWithPath: "/SDK"))
        #expect(args == ["-x", "objective-c++", "-target", "arm64-apple-ios16.0", "-isysroot", "/SDK", "-std=gnu++14", "-stdlib=libc++",
                         "-fobjc-arc", "-fobjc-weak", "-fmodules", "-fno-cxx-modules", "-fpascal-strings", "-Os", "-fno-common",
                         "-DNS_BLOCK_ASSERTIONS=1", "-DOBJC_OLD_DISPATCH_PROTOTYPES=0", "-fvisibility=hidden", "-fvisibility-inlines-hidden",
                         "-I", "/W/include", "-c", "/W/Sources/app/main.mm", "-o", "/W/.xless/obj/main.o"])
    }

    @Test func compileArgumentsForC() {
        let args = NativeLink.compileArguments(source: "/W/a.c", object: "/W/a.o", headerSearchPaths: [], minOS: "16.0", sdk: URL(fileURLWithPath: "/SDK"))
        #expect(args == ["-x", "c", "-target", "arm64-apple-ios16.0", "-isysroot", "/SDK", "-fmodules", "-fpascal-strings", "-Os", "-fno-common",
                         "-DNS_BLOCK_ASSERTIONS=1", "-DOBJC_OLD_DISPATCH_PROTOTYPES=0", "-fvisibility=hidden", "-c", "/W/a.c", "-o", "/W/a.o"])
    }

    /// Spike A's link line with spike B's binary-dependency flags (contract, "Fixes the Mac line needed on Linux" and
    /// spike B difference 9): cargo's output dir first and its staticlib by name (no Externals/libapp.a copy), flags
    /// before the libraries, -F per xcframework slice, no extra -lc++.
    @Test func linkArgumentsInContractOrder() {
        let inputs = NativeLink.LinkInputs(
            objects: ["/W/.xless/obj/main.o"], libraryPaths: ["/W/src-tauri/target/aarch64-apple-ios/release", "/SDK/usr/lib/swift"], libraries: ["acme_lib"],
            archives: ["/W/.xless/swift/libXlessTauriSwift.a"], frameworkPaths: ["/W/Pods/x/x.xcframework/ios-arm64"], frameworks: ["x"],
            linkFlags: ["-ObjC", "-lc++", "-weak_framework", "CoreML"], sdkFrameworks: ["CoreGraphics", "UIKit"],
            clangRuntime: "/TC/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a", swiftLibPaths: ["/SDK/usr/lib/swift", "/TC/usr/lib/swift/iphoneos"],
            minOS: "16.0", sdk: URL(fileURLWithPath: "/SDK"), ld64: URL(fileURLWithPath: "/B/toolset/bin/ld64.lld"), output: "/W/.xless/link/Acme")
        #expect(NativeLink.linkArguments(inputs) == [
            "-target", "arm64-apple-ios16.0", "-isysroot", "/SDK", "-Os", "-fuse-ld=/B/toolset/bin/ld64.lld", "-mlinker-version=907",
            "-L", "/W/src-tauri/target/aarch64-apple-ios/release", "-L", "/SDK/usr/lib/swift", "-L", "/TC/usr/lib/swift/iphoneos",
            "-F", "/W/Pods/x/x.xcframework/ios-arm64",
            "/W/.xless/obj/main.o",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks", "-Xlinker", "-dead_strip",
            "-stdlib=libc++", "-fobjc-arc", "-fobjc-link-runtime",
            "-ObjC", "-lc++", "-weak_framework", "CoreML", "-framework", "x",
            "-lacme_lib", "/W/.xless/swift/libXlessTauriSwift.a", "/TC/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a",
            "-framework", "CoreGraphics", "-framework", "UIKit",
            "-o", "/W/.xless/link/Acme",
        ])
    }

    /// project.yml dependencies plus the overlay: `libapp.a` is dropped (cargo's staticlib is linked in place); a binary dependency's xcframework gets its slice
    /// on -F, its linkFlags and one `-framework` (the project.yml entry for the same xcframework adds nothing); a
    /// CocoaPods `Pods_<target>` framework is dropped (spike B, open question 5).
    @Test func dependencyInputs() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("deps-\(UUID().uuidString)", isDirectory: true)
        let slice = work.appendingPathComponent("src-tauri/gen/apple/Pods/x/x.xcframework/ios-arm64/x.framework")
        try fm.createDirectory(at: slice, withIntermediateDirectories: true)
        let (_, parsed) = try XcodeGenProject.parse(yaml: fixture("project-acme.yml"), file: "project.yml")
        var target = parsed
        target.dependencies.append(.framework(path: "Pods_acme_iOS.framework", embed: false, codeSign: false))
        target.dependencies.append(.sdk("UIKit.framework"))
        target.dependencies.append(.sdk("libz.tbd"))
        let overlay = try TauriOverlay.parse(yaml: """
            type: tauri
            bundleID: com.example.acme
            teamID: ABCDE12345
            linkFlags: ["-ObjC"]
            binaryDependencies:
              - url: https://example.com/x.zip
                sha256: \(String(repeating: "a", count: 64))
                extract: x.xcframework
                to: src-tauri/gen/apple/Pods/x/x.xcframework
                linkFlags: ["-lc++", "-weak_framework", "CoreML"]
            """, name: "acme")
        let deps = try NativeLink.dependencyInputs(target: target, overlay: overlay, workRoot: work, appleDir: "src-tauri/gen/apple")
        #expect(deps.libraries == ["z"])   // libapp.a is not linked: the build links cargo's staticlib in place
        #expect(deps.frameworkPaths == [slice.deletingLastPathComponent().path])
        #expect(deps.frameworks == ["x"])
        #expect(deps.linkFlags == ["-ObjC", "-lc++", "-weak_framework", "CoreML"])
        #expect(deps.sdkFrameworks == ["CoreGraphics", "Metal", "UIKit", "WebKit"])
    }
}
