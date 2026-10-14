public struct ASCDocument<D: Codable & Sendable>: Codable, Sendable {
    public var data: D
    public init(data: D) { self.data = data }
}

public struct ASCResource<A: Codable & Sendable>: Codable, Sendable {
    public var type: String
    public var id: String
    public var attributes: A
}

public struct ASCRef: Codable, Sendable, Equatable {
    public var type: String
    public var id: String
    public init(type: String, id: String) { self.type = type; self.id = id }
}

public struct ASCToOne: Codable, Sendable { public var data: ASCRef?; public init(_ ref: ASCRef) { data = ref } }
public struct ASCToMany: Codable, Sendable { public var data: [ASCRef]; public init(_ refs: [ASCRef]) { data = refs } }

/// Body for POST requests: { data: { type, attributes, relationships } }.
public struct ASCCreate<A: Codable & Sendable, R: Codable & Sendable>: Codable, Sendable {
    public struct Inner: Codable, Sendable { public var type: String; public var attributes: A; public var relationships: R? }
    public var data: Inner
    public init(type: String, attributes: A, relationships: R? = nil) { data = .init(type: type, attributes: attributes, relationships: relationships) }
}

/// Body for PATCH requests: { data: { type, id, attributes } }.
public struct ASCUpdate<A: Codable & Sendable>: Codable, Sendable {
    public struct Inner: Codable, Sendable { public var type: String; public var id: String; public var attributes: A }
    public var data: Inner
    public init(type: String, id: String, attributes: A) { data = .init(type: type, id: id, attributes: attributes) }
}

public struct ASCNoRelationships: Codable, Sendable { public init() {} }
public struct ASCEmpty: Codable, Sendable {}
