import Foundation

/// native messaging 的 stdio 帧编解码：4 字节本机字节序 uint32 长度 + JSON 载荷。
public enum NativeMessagingFrame {
    /// 编码一帧（长度前缀 + 载荷），供测试与发送方复用
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }

    public enum FrameError: Error, CustomStringConvertible {
        case prematureEnd
        case oversized(limit: Int)

        public var description: String {
            switch self {
            case .prematureEnd:
                return "stdio 流提前结束"
            case .oversized(let limit):
                return "消息超过长度上限 \(limit) 字节"
            }
        }
    }

    /// Chrome native messaging 单条消息上限为 1MB（host → 扩展方向），取宽松上限防失控
    public static let maxMessageLength = 64 * 1024 * 1024

    public static func read(from handle: FileHandle) throws -> Data {
        let lengthData = try readExactly(4, from: handle)
        let length: UInt32 = lengthData.withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        guard Int(length) <= maxMessageLength else {
            throw FrameError.oversized(limit: maxMessageLength)
        }
        return try readExactly(Int(length), from: handle)
    }

    public static func write(_ payload: Data, to handle: FileHandle) throws {
        var length = UInt32(payload.count).littleEndian
        let lengthData = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(lengthData, to: handle)
        try writeAll(payload, to: handle)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            if chunk.isEmpty {
                throw FrameError.prematureEnd
            }
            data.append(chunk)
        }
        return data
    }

    private static func writeAll(_ data: Data, to handle: FileHandle) throws {
        var offset = 0
        while offset < data.count {
            let sub = data.subdata(in: offset..<data.count)
            handle.write(sub)
            offset += sub.count
        }
    }
}
