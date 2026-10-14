import Foundation

public enum PEM {
    /// Undoes what CI secret stores commonly do to PEM values: CRLF or CR line endings, literal "\n" escapes, and
    /// surrounding whitespace. Used for every PEM secret (ASC_KEY_P8, XLESS_DIST_KEY, XLESS_DEVID_KEY).
    public static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
