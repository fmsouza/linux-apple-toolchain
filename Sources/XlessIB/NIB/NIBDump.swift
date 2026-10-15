import Foundation

public enum NIBDump {
    public static func render(_ a: NIBArchive) -> String {
        var out = "NIBArchive format=\(a.formatVersion) coder=\(a.coderVersion) objects=\(a.objects.count) keys=\(a.keys.count) values=\(a.values.count) classes=\(a.classNames.count)\n"
        for (n, o) in a.objects.enumerated() {
            let cls = a.classNames[o.classNameIndex]
            out += "#\(n) \(cls.string)\(cls.extras.isEmpty ? "" : " extras=\(cls.extras)")\n"
            for v in a.values[o.valuesStart..<(o.valuesStart + o.valueCount)] {
                out += "  \(String(decoding: a.keys[v.keyIndex], as: UTF8.self)) = \(describe(v.data))\n"
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F || u.value == 0x2028 || u.value == 0x2029 { out += "\\u{" + String(u.value, radix: 16) + "}" }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    static func describe(_ v: NIBValueData) -> String {
        switch v {
        case .int8(let x): "int8 \(x)"
        case .int16(let x): "int16 \(x)"
        case .int32(let x): "int32 \(x)"
        case .int64(let x): "int64 \(x)"
        case .bool(let b): b ? "true" : "false"
        case .float(let f): "float \(f) [\(String(f.bitPattern, radix: 16))]"
        case .double(let f): "double \(f) [\(String(f.bitPattern, radix: 16))]"
        case .data(let d): "data[\(d.count)] \(d.prefix(64).map { String(format: "%02x", $0) }.joined())" + (String(data: d, encoding: .utf8).map { " \"\(escape($0))\"" } ?? "")
        case .null: "nil"
        case .object(let r): "@\(r)"
        }
    }
}
