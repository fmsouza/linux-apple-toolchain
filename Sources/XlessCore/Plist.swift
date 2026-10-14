import Foundation

public enum Plist {
    public static func read(_ url: URL, stage: Stage) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XlessError(stage, "cannot read \(url.path)", fix: "check the previous stage produced it")
        }
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XlessError(stage, "\(url.path) is not a dictionary plist", fix: "check the file contents")
        }
        return dict
    }

    public static func write(_ dict: [String: Any], to url: URL,
                             format: PropertyListSerialization.PropertyListFormat = .binary, stage: Stage) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
            try data.write(to: url)
        } catch {
            throw XlessError(stage, "cannot write plist \(url.path): \(error)", fix: "check disk space and permissions")
        }
    }
}
