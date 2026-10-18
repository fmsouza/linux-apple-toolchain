import Foundation
import XlessCore
import XlessMachO

/// Tools Swift Build runs from the Xcode toolchain while building and embedding products, for Linux
/// (docs/research/react-native-ios-contract.md, "Gate G3/G4"). Each implements exactly the command lines measured
/// there and refuses anything else with exit 70 and the argv, as `XcrunShim`.
public struct ToolShimUnsupported: Error, CustomStringConvertible, Equatable {
    public let tool: String
    public let argv: [String]
    public let reason: String
    public var description: String { "\(tool) shim: unsupported call (\(reason)): \(tool) \(argv.joined(separator: " "))" }
}

/// `strip` as Swift Build runs it, in exactly the two measured forms (options in any order):
/// - the copy phase's strip of an embedded binary (`COPY_PHASE_STRIP`): `strip -D -S -no_atom_info <src> -o <dst>`;
/// - the `Strip` task of an installed product (`STRIP_STYLE` debugging, Swift symbols with dSYMs): `strip -D -S -T
///   <file>`, in place; Swift packages' static library products (archives of Mach-O objects) get it too.
/// LLVM's `llvm-strip` takes the same `-D`, `-S` and `-T`; one measured difference: its `-T` also drops exported Swift
/// symbols from the symbol table (the export trie, which linkers and dyld read, is the same as Apple's).
/// `-no_atom_info` (drop `LC_ATOM_INFO`) is dropped because `ld64.lld` never writes that load command, which the shim
/// checks. Anything else is refused with exit 70 and the argv.
/// LLVM 21's `llvm-strip` lays the string pool out right after the indirect symbol table (4-byte entries), so it can
/// start 4 bytes off the 8-byte boundary that dyld requires ("mis-aligned LINKEDIT string pool"): after a successful
/// `llvm-strip`, the shim re-lays the output's tail (`MachO.alignLinkeditStringPool`) and refuses (exit 70) a layout it
/// does not understand or one dyld would still refuse. Archives are left as `llvm-strip` wrote them: their members are
/// objects, which only the static linker reads (dyld never loads them).
public enum StripShim {
    static let lcAtomInfo: UInt32 = 0x36
    static let copyPhase: Set<String> = ["-D", "-S", "-no_atom_info"]
    static let stripTask: Set<String> = ["-D", "-S", "-T"]

    /// The input, the file `llvm-strip` writes (the input itself for `-T`, in place) and the `llvm-strip` arguments for
    /// an Apple `strip` command line.
    public static func llvmArguments(_ args: [String]) throws -> (input: String, output: String, arguments: [String]) {
        func refuse(_ reason: String) -> ToolShimUnsupported { ToolShimUnsupported(tool: "strip", argv: args, reason: reason) }
        var options: [String] = [], input: String?, output: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-o" {
                guard i + 1 < args.count, output == nil else { throw refuse("-o needs one output") }
                output = args[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-") {
                guard copyPhase.contains(a) || stripTask.contains(a), !options.contains(a) else { throw refuse("option \(a)") }
                options.append(a)
            } else {
                guard input == nil else { throw refuse("more than one input") }
                input = a
            }
            i += 1
        }
        guard let input else { throw refuse("no input") }
        switch (Set(options), output) {
        case (copyPhase, let output?):
            return (input, output, ["-D", "-S", input, "-o", output])
        case (stripTask, nil):
            return (input, input, ["-D", "-S", "-T", input])
        default:
            throw refuse("only `-D -S -no_atom_info <src> -o <dst>` and `-D -S -T <file>` are measured")
        }
    }

    /// Refuses inputs `llvm-strip` must not see: neither Mach-O nor (for `-D -S -T`, as Swift Build strips the static
    /// library products of Swift packages) an `ar` archive, or (with `-no_atom_info`) an image carrying `LC_ATOM_INFO`.
    public static func checkInput(_ data: Data, path: String, args: [String]) throws {
        if data.prefix(8) == Data("!<arch>\n".utf8) {
            guard args.contains("-T") else {
                throw ToolShimUnsupported(tool: "strip", argv: args, reason: "\(path) is an archive; only `-D -S -T` was measured on archives")
            }
            return
        }
        guard MachO.isMachO(data) else {
            throw ToolShimUnsupported(tool: "strip", argv: args, reason: "\(path) is not a Mach-O image")
        }
        if args.contains("-no_atom_info"), (try? MachO.loadCommandTypes(in: data))?.contains(lcAtomInfo) ?? true {
            throw ToolShimUnsupported(tool: "strip", argv: args, reason: "\(path) has LC_ATOM_INFO or unreadable load commands")
        }
    }

    /// The post-pass on `llvm-strip`'s output: the re-laid image, or nil when it is fine as it is (an archive, thin or
    /// in a fat wrapper, which dyld never loads; or a string pool already aligned). Refuses a fat file mixing images and
    /// other slices, a layout `alignLinkeditStringPool` does not understand, and an output dyld would still refuse (a
    /// table other than the string pool misaligned, which `llvm-strip` does not do).
    public static func alignOutput(_ data: Data, path: String, args: [String]) throws -> Data? {
        func refuse(_ reason: String) -> ToolShimUnsupported { ToolShimUnsupported(tool: "strip", argv: args, reason: reason) }
        let loadable: Bool
        do { loadable = try MachO.containsLoadableImage(data) } catch {
            throw refuse("llvm-strip's output \(path) cannot be aligned: \(error)")
        }
        guard loadable else { return nil }
        let aligned: Data
        do { aligned = try MachO.alignLinkeditStringPool(in: data) } catch {
            throw refuse("cannot align the LINKEDIT string pool of llvm-strip's output \(path): \(error)")
        }
        let problems = (try? MachO.linkeditAlignmentProblems(in: aligned)) ?? ["unreadable load commands"]
        guard problems.isEmpty else {
            throw refuse("llvm-strip's output \(path) is still mis-aligned for dyld: \(problems.joined(separator: "; "))")
        }
        return aligned == data ? nil : aligned
    }

    /// The post-pass that makes `llvm-strip`'s indirect symbol table independent of the host architecture
    /// (`MachO.normalizeStrippedIndirectSymbols`): the output with it applied, or nil when nothing changes.
    public static func normalizeIndirectSymbols(original: Data, stripped: Data, path: String, args: [String]) throws -> Data? {
        do { return try MachO.normalizeStrippedIndirectSymbols(original: original, stripped: stripped) } catch {
            throw ToolShimUnsupported(tool: "strip", argv: args, reason: "cannot read the indirect symbol table of llvm-strip's output \(path): \(error)")
        }
    }

    /// The whole shim: maps `args`, checks the input, runs `llvmStrip` (inherited stdio) and, when it succeeds,
    /// aligns its output in place (permissions kept). Returns `llvm-strip`'s exit status (128 + signal when killed), or
    /// 1 when the input cannot be read; throws `ToolShimUnsupported` for a refusal.
    public static func run(_ args: [String], llvmStrip: String) throws -> Int32 {
        let mapped = try llvmArguments(args)
        guard let data = FileManager.default.contents(atPath: mapped.input) else {
            FileHandle.standardError.write(Data("strip: can't open file: \(mapped.input)\n".utf8))
            return 1
        }
        try checkInput(data, path: mapped.input, args: args)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: llvmStrip)
        p.arguments = mapped.arguments
        try p.run()
        p.waitUntilExit()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            return p.terminationReason == .exit ? p.terminationStatus : 128 + p.terminationStatus
        }
        guard var out = FileManager.default.contents(atPath: mapped.output) else {
            throw ToolShimUnsupported(tool: "strip", argv: args, reason: "llvm-strip wrote no \(mapped.output)")
        }
        let normalized = try normalizeIndirectSymbols(original: data, stripped: out, path: mapped.output, args: args)
        if let normalized { out = normalized }
        if let aligned = try alignOutput(out, path: mapped.output, args: args) ?? normalized {
            let url = URL(fileURLWithPath: mapped.output)
            let mode = (try? FileManager.default.attributesOfItem(atPath: mapped.output))?[.posixPermissions]
            try aligned.write(to: url, options: .atomic)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: mapped.output) }
        }
        return 0
    }
}

/// The linker Swift Build runs (the toolset's `linker`), in front of the SDK's `ld64.lld` trampoline. `ld64.lld`
/// has no relocatable (`-r`) output, so the trampoline turns a `-r` link into a static archive of its inputs (Swift
/// Build prelinks Swift package targets into `<target>.o` that way, `MACH_O_TYPE = mh_object`). Linked as an archive,
/// such a file only contributes the members something references, so a framework built from package targets came
/// out empty. A linker given an object includes all of it: each input named `*.o` that is an `ar` archive is passed
/// as `-force_load <path>` (also inside `-filelist` files), which is the same. `-r` links pass through.
///
/// `ld64.lld` 21 crashes (SIGSEGV in `ObjCMethListSection::setUp`, `Reloc::getReferentString`) when it converts the
/// Objective-C method lists of an object without `MH_SUBSECTIONS_VIA_SYMBOLS` to relative method lists, which it
/// does by default as Xcode's linker does. Vendored frameworks whose binary is such a prelinked object (Google's
/// MLKit frameworks) hit it, so a link with one gets `-no_objc_relative_method_lists`: that binary keeps
/// pointer-based method lists, which the Objective-C runtime reads the same way.
public enum LinkerShim {
    static let mhObject: UInt32 = 1
    static let subsectionsViaSymbols: UInt32 = 0x2000

    /// True for a thin or fat Mach-O file whose arm64 image is an `MH_OBJECT` without `MH_SUBSECTIONS_VIA_SYMBOLS`.
    public static func isObjectWithoutSubsections(_ data: Data) -> Bool {
        guard MachO.isMachO(data), let slices = try? MachO.sliceArchitectures(in: data),
              let arm64 = slices.first(where: { $0.name == "arm64" }), arm64.range.count >= 28 else { return false }
        func u32(_ at: Int) -> UInt32 {
            data[(arm64.range.lowerBound + at)..<(arm64.range.lowerBound + at + 4)].enumerated()
                .reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        return u32(12) == mhObject && u32(24) & subsectionsViaSymbols == 0
    }

    /// The binaries `-framework`/`-weak_framework` options name, found in the `-F` directories in order.
    static func frameworkBinaries(_ args: [String], fileExists: (String) -> Bool) -> [String] {
        var dirs: [String] = [], names: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-F", i + 1 < args.count { dirs.append(args[i + 1]); i += 2; continue }
            if a.hasPrefix("-F"), a.count > 2 { dirs.append(String(a.dropFirst(2))) }
            if a == "-framework" || a == "-weak_framework", i + 1 < args.count { names.append(args[i + 1]); i += 2; continue }
            i += 1
        }
        return names.compactMap { name in dirs.lazy.map { "\($0)/\(name).framework/\(name)" }.first(where: fileExists) }
    }

    public static func isArchive(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 8)) == Data("!<arch>\n".utf8)
    }

    /// The trampoline's arguments. `readFileList` returns a `-filelist` file's lines; `writeFileList` writes the
    /// remaining lines to a new file and returns its path. `fileExists` and `readFile` (a file's contents; the shim
    /// maps it, only the Mach-O and fat headers are read) find the framework binaries that need
    /// `-no_objc_relative_method_lists`. Only frameworks are checked: an object without subsections inside an archive,
    /// or passed as `-l`/`.a`, is not (not seen so far).
    public static func arguments(_ args: [String], isArchive: (String) -> Bool, readFileList: (String) throws -> [String],
                                 writeFileList: (String, [String]) throws -> String,
                                 fileExists: (String) -> Bool = { _ in false }, readFile: (String) -> Data? = { _ in nil }) throws -> [String] {
        if args.contains("-r") { return args }
        var out: [String] = []
        let needsAbsoluteLists = !args.contains("-no_objc_relative_method_lists")
            && frameworkBinaries(args, fileExists: fileExists).contains { readFile($0).map(isObjectWithoutSubsections) ?? false }
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-filelist", i + 1 < args.count {
                var kept: [String] = []
                for line in try readFileList(args[i + 1]) where !line.isEmpty {
                    if line.hasSuffix(".o"), isArchive(line) { out += ["-force_load", line] } else { kept.append(line) }
                }
                out += ["-filelist", try writeFileList(args[i + 1], kept)]
                i += 2
                continue
            }
            if !a.hasPrefix("-"), a.hasSuffix(".o"), i == 0 || !takesValue(args[i - 1]), isArchive(a) {
                out += ["-force_load", a]
            } else {
                out.append(a)
            }
            i += 1
        }
        return needsAbsoluteLists ? out + ["-no_objc_relative_method_lists"] : out
    }

    /// ld64 options whose next argument is a value, not an input (so `-o x.o` is never rewritten).
    static func takesValue(_ option: String) -> Bool {
        ["-o", "-object_path_lto", "-final_output", "-dependency_info", "-install_name", "-rpath", "-arch", "-syslibroot",
         "-platform_version", "-L", "-F", "-framework", "-weak_framework", "-exported_symbols_list", "-force_load",
         "-lto_library", "-map", "-order_file", "-sectcreate", "-alias", "-u", "-e"].contains(option)
    }
}

/// `embeddedBinaryValidationUtility <appex> -info-plist-path <host Info.plist> [-signing-cert ""]`: Swift Build's
/// `ValidateEmbeddedBinary` task after an app extension is copied into its app. Checks and messages are Xcode
/// 27.0's, black-box: the extension's bundle identifier must start with the app's (error, exit 1); otherwise a
/// different `CFBundleVersion`, else a different `CFBundleShortVersionString`, is a warning (only the first is reported).
public enum EmbeddedBinaryValidation {
    public struct Result: Equatable {
        public var stderr: String
        public var exitCode: Int32
    }

    public static func run(_ args: [String]) throws -> Result {
        func refuse(_ reason: String) -> ToolShimUnsupported {
            ToolShimUnsupported(tool: "embeddedBinaryValidationUtility", argv: args, reason: reason)
        }
        var binary: String?, hostPlist: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-info-plist-path":
                guard i + 1 < args.count, hostPlist == nil else { throw refuse("-info-plist-path needs one path") }
                hostPlist = args[i + 1]; i += 2
            case "-signing-cert":
                guard i + 1 < args.count, args[i + 1].isEmpty else { throw refuse("signing (the sign stage signs)") }
                i += 2
            case let a where a.hasPrefix("-"):
                throw refuse("option \(a)")
            default:
                guard binary == nil else { throw refuse("more than one binary") }
                binary = args[i]; i += 1
            }
        }
        guard let binary, binary.hasSuffix(".appex") else { throw refuse("only app extensions (.appex) are validated") }
        guard let hostPlist else { throw refuse("no -info-plist-path") }
        let ext = try plist(binary + "/Info.plist", refuse), host = try plist(hostPlist, refuse)
        guard let extID = ext["CFBundleIdentifier"] as? String, let hostID = host["CFBundleIdentifier"] as? String else {
            throw refuse("a bundle without CFBundleIdentifier")
        }
        if !extID.hasPrefix(hostID) {
            return Result(stderr: "error: Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier.\n\n"
                + "\t\tEmbedded Binary Bundle Identifier:\t\(extID)\n\t\tParent App Bundle Identifier:\t\t\(hostID)\n\n\n", exitCode: 1)
        }
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            let e = ext[key] as? String, h = host[key] as? String
            if e != h {
                func show(_ v: String?) -> String { v.map { "('\($0)')" } ?? "(null)" }
                return Result(stderr: "warning: The \(key) of an app extension \(show(e)) must match that of its containing parent app \(show(h)).\n",
                              exitCode: 0)
            }
        }
        return Result(stderr: "", exitCode: 0)
    }

    static func plist(_ path: String, _ refuse: (String) -> ToolShimUnsupported) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw refuse("cannot read the Info dictionary at \(path)")
        }
        return dict
    }
}
