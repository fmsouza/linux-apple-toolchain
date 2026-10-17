import Foundation

public struct Greeter {
    public init() {}
    public func shout(_ text: String) -> String { text.uppercased() + "!" }
}
