import Foundation
import Testing
@testable import XlessCore

// Expected output and messages are /usr/libexec/PlistBuddy's for the same commands (macOS 27); the commands are the
// ones Expo dev launcher's "Strip Local Network Keys" phase and React Native Firebase's ios_config.sh run.

private func infoPlist() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Info.plist")
    let root: [String: Any] = ["Name": "Hello World", "NSBonjourServices": ["_http._tcp", "_expo._tcp"],
                               "NSLocalNetworkUsageDescription": "Expo Dev Launcher uses the local network",
                               "D": ["k": true, "n": 1.5, "i": -2] as [String: Any], "B": false, "I": 42]
    // Swift Build writes the built Info.plist in binary form.
    try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    return url
}

private func pb(_ args: [String]) -> PlistBuddyShim.Result { PlistBuddyShim.run(args) }

@Test func printsValuesAsPlistBuddy() throws {
    let f = try infoPlist().path
    #expect(pb(["-c", "Print :Name", f]) == .init(stdout: "Hello World\n", stderr: "", exitCode: 0))
    #expect(pb(["-c", "Print :NSBonjourServices", f]).stdout == "Array {\n    _http._tcp\n    _expo._tcp\n}\n")
    #expect(pb(["-c", "Print :NSBonjourServices:1", f]).stdout == "_expo._tcp\n")
    #expect(pb(["-c", "Print :B", f]).stdout == "false\n")
    #expect(pb(["-c", "Print :I", f]).stdout == "42\n")
    #expect(pb(["-c", "Print :D:n", f]).stdout == "1.500000\n")
    #expect(pb(["-c", "Print :D:k", f]).stdout == "true\n")
    #expect(pb(["-c", "Print :D", f]).stdout == "Dict {\n    i = -2\n    k = true\n    n = 1.500000\n}\n")   // keys sorted (PlistBuddy: hash order)
    #expect(pb(["-c", "Print :Nope", f]) == .init(stdout: "", stderr: "Print: Entry, \":Nope\", Does Not Exist\n", exitCode: 1))
    #expect(pb(["-c", "Print :NSBonjourServices:7", f]).stderr == "Print: Entry, \":NSBonjourServices:7\", Does Not Exist\n")
}

@Test func editsAndSavesAsXML() throws {
    let url = try infoPlist(), f = url.path
    #expect(pb(["-c", "Delete :NSBonjourServices:1", f]).exitCode == 0)
    #expect(pb(["-c", "Delete :NSLocalNetworkUsageDescription", f]).exitCode == 0)
    #expect(pb(["-c", "Delete :NSLocalNetworkUsageDescription", f]) == .init(stdout: "", stderr: "Delete: Entry, \":NSLocalNetworkUsageDescription\", Does Not Exist\n", exitCode: 1))
    #expect(pb(["-c", "Add :firebase_json_raw string 'eyJhIjoxfQ=='", f]).exitCode == 0)
    #expect(pb(["-c", "Add :firebase_json_raw string 'x'", f]) == .init(stdout: "", stderr: "Add: \":firebase_json_raw\" Entry Already Exists\n", exitCode: 1))
    #expect(pb(["-c", "Add :FirebaseDataCollectionDefaultEnabled bool 'NO'", f]).exitCode == 0)
    #expect(pb(["-c", "Add :FIREBASE_ANALYTICS_COLLECTION_ENABLED bool 'YES'", f]).exitCode == 0)
    #expect(pb(["-c", "Set :Name 'New Name'", f]).exitCode == 0)
    #expect(pb(["-c", "Set :B YES", f]).exitCode == 0)
    #expect(pb(["-c", "Set :I 7", f]).exitCode == 0)
    #expect(pb(["-c", "Set :Nope x", f]).stderr == "Set: Entry, \":Nope\", Does Not Exist\n")
    #expect(pb(["-c", "Set :D x", f]).stderr == "Set: Cannot Perform Set On Containers\n")
    #expect(pb(["-c", "Add :Arr array", "-c", "Add :Arr:0 string x", "-c", "Add :Arr: string y", "-c", "Print :Arr", f]).stdout == "Array {\n    x\n    y\n}\n")
    // A failing command does not stop the later ones; the status is 1.
    #expect(pb(["-c", "Add :Name string y", "-c", "Print :Name", f]) == .init(stdout: "New Name\n", stderr: "Add: \":Name\" Entry Already Exists\n", exitCode: 1))

    let data = try Data(contentsOf: url)
    #expect(data.starts(with: Data("<?xml".utf8)))
    let root = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    #expect(root["NSBonjourServices"] as? [String] == ["_http._tcp"])
    #expect(root["NSLocalNetworkUsageDescription"] == nil)
    #expect(root["firebase_json_raw"] as? String == "eyJhIjoxfQ==")
    #expect(root["Name"] as? String == "New Name")
    #expect(pb(["-c", "Print :FirebaseDataCollectionDefaultEnabled", f]).stdout == "false\n")
    #expect(pb(["-c", "Print :FIREBASE_ANALYTICS_COLLECTION_ENABLED", f]).stdout == "true\n")
    #expect(pb(["-c", "Print :B", f]).stdout == "true\n")
    #expect(pb(["-c", "Print :I", f]).stdout == "7\n")
}

@Test func missingFileIsCreatedOnlyWhenEdited() throws {
    let dir = try infoPlist().deletingLastPathComponent()
    let missing = dir.appendingPathComponent("missing.plist").path
    #expect(pb(["-c", "Print :X", missing]) == .init(stdout: "File Doesn't Exist, Will Create: \(missing)\n", stderr: "Print: Entry, \":X\", Does Not Exist\n", exitCode: 1))
    #expect(!FileManager.default.fileExists(atPath: missing))
    #expect(pb(["-c", "Add :K string v", missing]).exitCode == 0)
    #expect(pb(["-c", "Print :K", missing]).stdout == "v\n")
}

@Test(arguments: [
    (["-x", "-c", "Print :A", "f.plist"], "option -x"),
    (["f.plist"], "interactive mode"),
    (["-c", "Merge other.plist", "f.plist"], "command Merge other.plist"),
    (["-c", "Add :D date 2020-01-01", "f.plist"], "Add type date"),
    (["-c", "Print :a\\:b", "f.plist"], "entry :a\\:b"),
    (["-c", "Add :K string 'a' 'b'", "f.plist"], "quotes inside the value"),
])
func refusesOutsideTheSubset(args: [String], reason: String) {
    let r = pb(args)
    #expect(r.exitCode == 70)
    #expect(r.stderr.contains(reason))
    #expect(r.stderr.contains("PlistBuddy \(args.joined(separator: " "))"))
}
