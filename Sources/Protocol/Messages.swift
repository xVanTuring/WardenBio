import Foundation

/// Bitwarden 浏览器扩展 ↔ 桌面端生物识别解锁协议的消息模型。
/// 与官方扩展的 native messaging 协议保持字节级一致（参考 bw-bio-handler / goldwarden）。

/// 加密帧内容：`{"iv":..,"mac":..,"data":..,"encryptionType":2}`
/// 新版协议为 AesCbc256_HmacSha256（传输密钥 64 字节：前 32 加密、后 32 HMAC），
/// 兼容旧版 type 0 的读取。
public struct EncryptedString: Codable, Equatable {
    public var iv: String
    public var mac: String?
    public var data: String
    public var encryptionType: Int

    public init(iv: String, mac: String? = nil, data: String, encryptionType: Int = 2) {
        self.iv = iv
        self.mac = mac
        self.data = data
        self.encryptionType = encryptionType
    }

    private enum CodingKeys: String, CodingKey {
        case iv, mac, data, encryptionType, encryptedString
    }

    /// 扩展侧解密只认这个字符串形式（`<type>.<iv>|<data>|<mac>`）：
    /// 它会把 `encryptedString` 直接交给 SDK 的 symmetric_decrypt_string，
    /// 只给 iv/data/mac 会让那里拿到 undefined 并抛异常（表现为扩展一直转圈）。
    public var encryptedString: String {
        var value = "\(encryptionType).\(iv)|\(data)"
        if let mac = mac { value += "|\(mac)" }
        return value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(iv, forKey: .iv)
        try container.encodeIfPresent(mac, forKey: .mac)
        try container.encode(data, forKey: .data)
        try container.encode(encryptionType, forKey: .encryptionType)
        try container.encode(encryptedString, forKey: .encryptedString)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iv = try container.decode(String.self, forKey: .iv)
        mac = try container.decodeIfPresent(String.self, forKey: .mac)
        data = try container.decode(String.self, forKey: .data)
        encryptionType = try container.decodeIfPresent(Int.self, forKey: .encryptionType) ?? 0
    }
}

/// 从扩展收到的顶层消息：`{"appId":..,"message":..}`
public struct IncomingMessage: Decodable {
    public let appId: String?
    public let message: JSONValue?
}

/// 明文 `message` 字段：`{"command":"setupEncryption","publicKey":..,"userId":..}`
public struct UnencryptedRequest: Decodable {
    public let command: String
    public let publicKey: String?
    public let userId: String?
}

/// 加密 `message` 字段解密后的载荷：`{"command":..,"userId":..,"messageId":..,"timestamp":..}`
public struct PayloadRequest: Decodable {
    public let command: String
    public let userId: String?
    public let messageId: Int?
    public let timestamp: Int64?
    public let publicKey: String?
}

/// 发往扩展的顶层消息（可选字段为 nil 时自动省略）
public struct OutgoingMessage: Encodable {
    public var command: String?
    public var appId: String?
    public var messageId: Int?
    public var sharedSecret: String?
    public var message: EncryptedString?

    public init(command: String? = nil, appId: String? = nil, messageId: Int? = nil,
                sharedSecret: String? = nil, message: EncryptedString? = nil) {
        self.command = command
        self.appId = appId
        self.messageId = messageId
        self.sharedSecret = sharedSecret
        self.message = message
    }
}

/// 加密载荷里的通用应答（状态查询类）
public struct StatusResponse: Encodable {
    public let command: String
    public let messageId: Int
    public let response: Int
    public let timestamp: Int64

    public init(command: String, messageId: Int, response: Int) {
        self.command = command
        self.messageId = messageId
        self.response = response
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// `unlockWithBiometricsForUser` 的应答
public struct UnlockResponse: Encodable {
    public let command: String
    public let messageId: Int
    public let response: Bool
    public let userKeyB64: String?
    public let timestamp: Int64

    public init(messageId: Int, response: Bool, userKeyB64: String? = nil) {
        self.command = "unlockWithBiometricsForUser"
        self.messageId = messageId
        self.response = response
        self.userKeyB64 = userKeyB64
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// BiometricsStatus 枚举（与 libs/key-management 的 TS 数字枚举一致）
public enum BiometricsStatusValue {
    public static let available = 0
    public static let unlockNeeded = 1
    public static let hardwareUnavailable = 2
    public static let desktopDisconnected = 6
    public static let notEnabledLocally = 7
    public static let notEnabledInConnectedDesktopApp = 8
}
