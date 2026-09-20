import Foundation

/// Bitwarden SDK IPC 协议（Noise 加密通道）的会话层。
/// 处理浏览器扩展发来的 `bitwarden-ipc-message` 信封：
/// - Frame 编解码（CBOR，serde 外部标签语义：普通 Vec<u8> → 整数数组，ByteBuf → 字节串）
/// - Noise 握手 / 传输加解密
/// - RPC 请求分发（discover / biometrics），应答按请求里的 response_topic 回发
///   （旧版 SDK 无该字段，固定用 `RpcResponseMessage`）
public struct SdkIpcSession {
    public enum IpcError: Swift.Error, CustomStringConvertible {
        case notReady
        case unknownFrame(String)

        public var description: String {
            switch self {
            case .notReady: return "Noise 会话尚未建立"
            case .unknownFrame(let why): return "未知 IPC 帧：\(why)"
            }
        }
    }

    /// 应答 discover 时上报的版本（与官方桌面客户端版本号同格式）
    public static let desktopVersion = "2026.9.0"

    /// 业务回调（由 BioHost 注入）
    public var unlockHandler: ((String) -> String?)?          // userId -> userKeyB64（失败 nil）
    public var authenticateHandler: (() -> Bool)?             // 仅验证不读密钥
    public var availabilityHandler: (() -> Bool)?             // 生物识别是否可用
    public var keyExistsHandler: ((String) -> Bool)?          // 账户是否已录入密钥

    private var transport: NoiseNN.Transport?

    public init() {}

    // MARK: - 入口

    /// 处理一条信封消息，返回需要回发的信封列表（可能为空）
    public mutating func handle(envelope: SdkIpcEnvelope) throws -> [SdkIpcEnvelope] {
        let frame = try Cbor.decode(Data(envelope.payload))

        // {"HandshakeStart": {"ciphersuite": "...", "noise_frame": [...]}}
        if let start = frame["HandshakeStart"] {
            let suite = start["ciphersuite"]?.textValue ?? ""
            guard suite == "Noise_NN_P256_AESGCM_SHA256" else {
                throw IpcError.unknownFrame("不支持的密码套件 \(suite)")
            }
            guard let noiseFrameValue = start["noise_frame"] else {
                throw IpcError.unknownFrame("缺少 noise_frame")
            }
            let frameData: Data
            switch noiseFrameValue {
            case .array(let items):
                frameData = Data(items.compactMap { $0.unsignedValue.map { UInt8($0) } })
            case .byteArray(let d):
                frameData = d
            default:
                throw IpcError.unknownFrame("noise_frame 形态异常")
            }
            let (finishFrame, responder) = try NoiseNN.Responder.respond(startFrame: frameData)
            transport = NoiseNN.Transport(responder: responder)
            Logger.shared.info("SDK IPC：Noise 握手完成（\(suite)，端点 \(envelope.endpoint)）")
            let finish = Cbor.Value.map([(.text("HandshakeFinish"), .array(
                finishFrame.map { .unsigned(UInt64($0)) }))])
            return [SdkIpcEnvelope(
                payload: Array(Cbor.encode(finish)), topic: nil, endpoint: envelope.endpoint)]
        }

        // {"TransportFrame": {"payload": h'..', "nonce": n}}
        if let tf = frame["TransportFrame"] {
            guard var t = transport else { throw IpcError.notReady }
            guard let payload = tf["payload"]?.bytesValue,
                  let nonce = tf["nonce"]?.unsignedValue else {
                throw IpcError.unknownFrame("TransportFrame 字段缺失")
            }
            let plaintext: Data
            do {
                plaintext = try t.decrypt(payload, nonce: nonce)
            } catch {
                // 解密失败：通知对端重置会话
                Logger.shared.error("SDK IPC：解密失败，发送 CryptoInvalidated：\(error)")
                transport = nil
                // 单元变体（无字段）在 CBOR 里就是裸字符串
                let invalidated = Cbor.Value.text("CryptoInvalidated")
                return [SdkIpcEnvelope(
                    payload: Array(Cbor.encode(invalidated)),
                    topic: nil,
                    endpoint: envelope.endpoint)]
            }
            transport = t
            return try handleRpc(plaintext: plaintext, endpoint: envelope.endpoint)
        }

        // "CryptoInvalidated"
        if case .text("CryptoInvalidated") = frame {
            Logger.shared.info("SDK IPC：对端重置会话")
            transport = nil
            return []
        }
        if frame["CryptoInvalidated"] != nil {
            Logger.shared.info("SDK IPC：对端重置会话")
            transport = nil
            return []
        }

        throw IpcError.unknownFrame("无法识别的 CBOR 帧")
    }

    // MARK: - RPC（载荷为 JSON，仅外层 Frame 是 CBOR）

    private mutating func handleRpc(plaintext: Data, endpoint: String) throws -> [SdkIpcEnvelope] {
        guard let request = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let requestId = request["request_id"] as? String,
              let requestType = request["request_type"] as? String else {
            throw IpcError.unknownFrame("RPC 请求缺少信封字段")
        }
        // DiscoverRequest / AuthenticateBiometrics 是无字段请求，request 为 null
        let requestPayload = request["request"] as? [String: Any]
        let userId = requestPayload?["user_id"] as? String

        Logger.shared.info("SDK IPC RPC：\(requestType)（id=\(requestId)）")

        // result 是 Rust `Result<T, RpcError>` 的外部标签形式：{"Ok": T} / {"Err": ...}
        let result: Any
        switch requestType {
        case "DiscoverRequest":
            result = ["Ok": ["version": Self.desktopVersion]]

        case "GetBiometricsStatus":
            result = ["Ok": biometricsStatus(userId: userId).rawValue]

        case "UnlockBiometrics":
            if let userId = userId, let key = unlockHandler?(userId) {
                Logger.shared.info("SDK IPC：解锁成功（userId=\(userId)）")
                result = ["Ok": ["user_key": key]]
            } else {
                Logger.shared.info("SDK IPC：解锁失败或被取消（userId=\(userId ?? "-")）")
                result = ["Ok": ["user_key": NSNull()]]
            }

        case "AuthenticateBiometrics":
            let passed = authenticateHandler?() ?? false
            Logger.shared.info("SDK IPC：AuthenticateBiometrics 结果 \(passed)")
            result = ["Ok": passed]

        default:
            Logger.shared.info("SDK IPC RPC：未知请求类型 \(requestType)，回 NoHandlerFound")
            result = ["Err": "NoHandlerFound"]
        }

        // IncomingRpcResponseMessage {result, request_id, request_type}（JSON）
        let response: [String: Any] = [
            "result": result,
            "request_id": requestId,
            "request_type": requestType,
        ]
        let plaintextData = try JSONSerialization.data(withJSONObject: response)
        // 新版请求自带 response_topic，旧版（如扩展内置的 0.2.0-main.950）固定用这个主题
        let topic = request["response_topic"] as? String ?? "RpcResponseMessage"

        guard var t = transport else { throw IpcError.notReady }
        let (sealed, nonce) = try t.encrypt(plaintextData)
        transport = t
        let frame: Cbor.Value = .map([(.text("TransportFrame"), .map([
            (.text("payload"), .byteArray(sealed)),
            (.text("nonce"), .unsigned(nonce)),
        ]))])
        return [SdkIpcEnvelope(payload: Array(Cbor.encode(frame)), topic: topic, endpoint: endpoint)]
    }

    // MARK: - 状态判定

    enum BiometricsStatus: String {
        case available = "Available"
        case unlockNeeded = "UnlockNeeded"
        case hardwareUnavailable = "HardwareUnavailable"
        case notEnabled = "NotEnabled"
    }

    func biometricsStatus(userId: String?) -> BiometricsStatus {
        let available = availabilityHandler?() ?? false
        guard available else { return .hardwareUnavailable }
        if let userId = userId, keyExistsHandler?(userId) == true {
            return .available
        }
        return .notEnabled
    }
}

/// 浏览器扩展的 IPC 信封（native messaging JSON 层）
public struct SdkIpcEnvelope {
    public var payload: [UInt8]
    public var topic: String?
    /// 本条消息对应的桌面端端点（DesktopMain / DesktopRenderer）。
    /// 扩展对「非转发」信封一律把 source 记作 DesktopMain，因此应答必须用
    /// `forwarded-bitwarden-ipc-message` + originalSource 标明真实端点，
    /// 否则发起方会因 source 与目标端点不符而丢弃该消息（表现为握手超时）。
    public var endpoint: String

    public init(payload: [UInt8], topic: String?, endpoint: String = "DesktopMain") {
        self.payload = payload
        self.topic = topic
        self.endpoint = endpoint
    }

    /// 从 native messaging JSON 解析；非 IPC 信封返回 nil
    public static func parse(data: Data) -> SdkIpcEnvelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "bitwarden-ipc-message",
              let message = obj["message"] as? [String: Any],
              let payload = message["payload"] as? [Int] else {
            return nil
        }
        let bytes = payload.map { UInt8(bitPattern: Int8(truncatingIfNeeded: $0)) }
        return SdkIpcEnvelope(
            payload: bytes,
            topic: message["topic"] as? String,
            endpoint: message["destination"] as? String ?? "DesktopMain")
    }

    /// 编码为发往扩展的 native messaging JSON。
    /// `message.destination` 在扩展侧不参与路由（真实桌面端填的是浏览器端点，
    /// 那由 desktop_proxy 与桌面端 socket 握手时分配，host 无从得知），
    /// 给一个合法的单例端点即可。
    public func encoded() throws -> Data {
        let message: [String: Any] = [
            "destination": "DesktopMain",
            "payload": payload.map { Int($0) },
            "topic": topic ?? NSNull(),
        ]
        let wrapper: [String: Any] = [
            "type": "forwarded-bitwarden-ipc-message",
            "message": message,
            "originalSource": endpoint,
        ]
        return try JSONSerialization.data(withJSONObject: wrapper)
    }
}
