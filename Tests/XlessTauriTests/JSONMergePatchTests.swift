import Testing
import Foundation
@testable import XlessTauri

private func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }
private func canon(_ v: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])) ?? Data(), as: UTF8.self)
}
private func equal(_ a: Any, _ b: Any) -> Bool { canon(a) == canon(b) }

/// RFC 7396 appendix A.
@Test(arguments: [
    (#"{"a":"b"}"#, #"{"a":"c"}"#, #"{"a":"c"}"#),
    (#"{"a":"b"}"#, #"{"b":"c"}"#, #"{"a":"b","b":"c"}"#),
    (#"{"a":"b"}"#, #"{"a":null}"#, #"{}"#),
    (#"{"a":"b","b":"c"}"#, #"{"a":null}"#, #"{"b":"c"}"#),
    (#"{"a":["b"]}"#, #"{"a":"c"}"#, #"{"a":"c"}"#),
    (#"{"a":"c"}"#, #"{"a":["b"]}"#, #"{"a":["b"]}"#),
    (#"{"a":{"b":"c"}}"#, #"{"a":{"b":"d","c":null}}"#, #"{"a":{"b":"d"}}"#),
    (#"{"a":[{"b":"c"}]}"#, #"{"a":[1]}"#, #"{"a":[1]}"#),
    (#"["a","b"]"#, #"["c","d"]"#, #"["c","d"]"#),
    (#"{"a":"b"}"#, #"["c"]"#, #"["c"]"#),
    (#"{"a":"foo"}"#, "null", "null"),
    (#"{"a":"foo"}"#, #""bar""#, #""bar""#),
    (#"{"e":null}"#, #"{"a":1}"#, #"{"e":null,"a":1}"#),
    (#"[1,2]"#, #"{"a":"b","c":null}"#, #"{"a":"b"}"#),
    ("{}", #"{"a":{"bb":{"ccc":null}}}"#, #"{"a":{"bb":{}}}"#),
])
func rfc7396(target: String, patch: String, expected: String) {
    #expect(equal(JSONMergePatch.apply(json(patch), to: json(target)), json(expected)))
}
