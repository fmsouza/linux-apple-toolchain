import Foundation

/// RFC 7396 JSON Merge Patch over `JSONSerialization` values.
public enum JSONMergePatch {
    /// A non-object patch replaces the target; in an object patch `NSNull` removes the key and other values merge recursively.
    public static func apply(_ patch: Any, to target: Any) -> Any {
        guard let p = patch as? [String: Any] else { return patch }
        var result = (target as? [String: Any]) ?? [:]
        for (key, value) in p {
            if value is NSNull {
                result.removeValue(forKey: key)
            } else {
                result[key] = apply(value, to: result[key] ?? [String: Any]())
            }
        }
        return result
    }
}
