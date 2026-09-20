import Foundation

/// 极简 CBOR 编解码（RFC 8949 子集），序列化语义对齐 Rust ciborium + serde：
/// - `Vec<u8>`（serde 默认）→ 整数数组
/// - `serde_bytes::ByteBuf` → 字节串（major type 2）
public enum Cbor {
    public enum Value {
        case null
        case bool(Bool)
        case unsigned(UInt64)
        case negative(Int64)
        case text(String)
        case byteArray(Data)          // major type 2
        case array([Value])
        case map([(Value, Value)])
    }

    // MARK: - 解码

    public static func decode(_ data: Data) throws -> Value {
        var cursor = 0
        let value = try decodeItem(data, &cursor)
        return value
    }

    private static func decodeItem(_ data: Data, _ cursor: inout Int) throws -> Value {
        guard cursor < data.count else { throw Error.truncated }
        let initial = data[data.startIndex + cursor]
        cursor += 1
        let major = initial >> 5
        let info = Int(initial & 0x1F)

        let argument: UInt64
        if info < 24 {
            argument = UInt64(info)
        } else if info == 24, cursor < data.count {
            argument = UInt64(data[data.startIndex + cursor]); cursor += 1
        } else if info == 25, cursor + 2 <= data.count {
            argument = UInt64(data[data.startIndex + cursor]) << 8
                | UInt64(data[data.startIndex + cursor + 1]); cursor += 2
        } else if info == 26, cursor + 4 <= data.count {
            var v: UInt64 = 0
            for i in 0..<4 {
                v = v << 8 | UInt64(data[data.startIndex + cursor + i])
            }
            argument = v; cursor += 4
        } else if info == 27, cursor + 8 <= data.count {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = v << 8 | UInt64(data[data.startIndex + cursor + i])
            }
            argument = v; cursor += 8
        } else {
            throw Error.unsupported("额外信息 \(info)")
        }

        func readBytes(_ count: Int) throws -> Data {
            guard cursor + count <= data.count else { throw Error.truncated }
            let range = (cursor + data.startIndex)..<(cursor + count + data.startIndex)
            cursor += count
            return data.subdata(in: range)
        }

        switch major {
        case 0: return .unsigned(argument)
        case 1: return .negative(Int64(bitPattern: ~argument))
        case 2: return .byteArray(try readBytes(Int(argument)))
        case 3: 
            let bytes = try readBytes(Int(argument))
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw Error.unsupported("非 UTF-8 文本")
            }
            return .text(text)
        case 4:
            let count = Int(argument)
            var items: [Value] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try decodeItem(data, &cursor)) }
            return .array(items)
        case 5:
            let count = Int(argument)
            var pairs: [(Value, Value)] = []
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try decodeItem(data, &cursor)
                let value = try decodeItem(data, &cursor)
                pairs.append((key, value))
            }
            return .map(pairs)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            default: throw Error.unsupported("简单值 info=\(info)")
            }
        default:
            throw Error.unsupported("major type \(major)")
        }
    }

    // MARK: - 编码

    public static func encode(_ value: Value) -> Data {
        var out = Data()
        encodeItem(value, into: &out)
        return out
    }

    private static func encodeItem(_ value: Value, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xF6)
        case .bool(let b):
            out.append(b ? 0xF5 : 0xF4)
        case .unsigned(let v):
            encodeHead(major: 0, argument: v, into: &out)
        case .negative(let v):
            let inverted: Int64 = ~v
            encodeHead(major: 1, argument: UInt64(bitPattern: inverted), into: &out)
        case .text(let s):
            let bytes = Data(s.utf8)
            encodeHead(major: 3, argument: UInt64(bytes.count), into: &out)
            out.append(bytes)
        case .byteArray(let d):
            encodeHead(major: 2, argument: UInt64(d.count), into: &out)
            out.append(d)
        case .array(let items):
            encodeHead(major: 4, argument: UInt64(items.count), into: &out)
            for item in items { encodeItem(item, into: &out) }
        case .map(let pairs):
            encodeHead(major: 5, argument: UInt64(pairs.count), into: &out)
            for (key, value) in pairs {
                encodeItem(key, into: &out)
                encodeItem(value, into: &out)
            }
        }
    }

    private static func encodeHead(major: UInt8, argument: UInt64, into out: inout Data) {
        let header = major << 5
        if argument < 24 {
            out.append(header | UInt8(argument))
        } else if argument <= UInt64(UInt8.max) {
            out.append(header | 24); out.append(UInt8(argument))
        } else if argument <= UInt64(UInt16.max) {
            out.append(header | 25)
            out.append(contentsOf: withUnsafeBytes(of: UInt16(argument).bigEndian) { Data($0) })
        } else if argument <= UInt64(UInt32.max) {
            out.append(header | 26)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(argument).bigEndian) { Data($0) })
        } else {
            out.append(header | 27)
            out.append(contentsOf: withUnsafeBytes(of: argument.bigEndian) { Data($0) })
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case truncated
        case unsupported(String)

        public var description: String {
            switch self {
            case .truncated: return "CBOR 数据不完整"
            case .unsupported(let why): return "不支持的 CBOR 元素：\(why)"
            }
        }
    }
}

extension Cbor.Value {
    public subscript(key: String) -> Cbor.Value? {
        if case .map(let pairs) = self {
            return pairs.first {
                if case .text(let t) = $0.0 { return t == key }
                return false
            }?.1
        }
        return nil
    }

    public var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var bytesValue: Data? {
        if case .byteArray(let d) = self { return d }
        return nil
    }

    public var unsignedValue: UInt64? {
        if case .unsigned(let v) = self { return v }
        return nil
    }
}
