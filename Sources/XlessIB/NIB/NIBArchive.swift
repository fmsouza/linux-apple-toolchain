import Foundation

public enum NIBSection: Int, Sendable, Hashable { case objects, keys, values, classNames }

public struct NIBObject: Equatable, Sendable { public var classNameIndex: Int; public var valuesStart: Int; public var valueCount: Int }

public enum NIBValueData: Equatable, Sendable {
    case int8(Int8), int16(Int16), int32(Int32), int64(Int64), bool(Bool), float(Float), double(Double), data(Data), null, object(UInt32)
}

public struct NIBValue: Equatable, Sendable { public var keyIndex: Int; public var data: NIBValueData }

public struct NIBClassName: Equatable, Sendable {
    public var name: Data          // without trailing NUL
    public var extras: [Int32]
    public var string: String { String(decoding: name, as: UTF8.self) }
}

public struct NIBArchive: Equatable, Sendable {
    public var formatVersion: UInt32 = 1
    public var coderVersion: UInt32 = 10
    public var objects: [NIBObject] = []
    public var keys: [Data] = []
    public var values: [NIBValue] = []
    public var classNames: [NIBClassName] = []
    /// Physical order of sections in the file, as read (writer reproduces it).
    public var sectionOrder: [NIBSection] = [.objects, .keys, .values, .classNames]
    /// Bytes after the end of the last section. Defaults to the `4C 4E 45 00` ("LNE\0") that every Xcode 27.0 golden has.
    public var trailer = Data([0x4C, 0x4E, 0x45, 0x00])
    public init() {}
}
