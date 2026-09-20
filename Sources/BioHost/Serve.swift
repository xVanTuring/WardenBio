import Foundation

/// Bitwarden 浏览器扩展生物识别解锁协议主循环（新版协议，与官方桌面客户端一致）。
/// 通信模型：浏览器 -stdio(native messaging)-> BioHost。
///
/// 流程：
/// 1. host 启动即发 `connected`
/// 2. 扩展发 `setupEncryption`（RSA 公钥 + userId），host 生成 64 字节传输密钥
///    （32 enc + 32 mac），用 RSA-OAEP-SHA1 加密回传
/// 3. 之后所有消息为 EncString type 2（AES-256-CBC + HMAC-SHA256）
/// 4. 命令：getBiometricsStatus / getBiometricsStatusForUser /
///    unlockWithBiometricsForUser / authenticateWithBiometrics
enum Serve {
    /// 官方桌面端允许的消息时间偏差（毫秒）
    private static let messageValidTimeoutMs: Int64 = 10_000

    static func run() {
        let log = Logger.shared
        log.info("host 启动 (pid \(ProcessInfo.processInfo.processIdentifier))")

        let transportKey: Data
        do {
            transportKey = try BrowserCrypto.generateTransportKey()
        } catch {
            log.error("生成传输密钥失败：\(error)")
            return
        }

        // 新版 SDK IPC 会话（Noise_NN），回调接 SecretStore
        var sdkIpc = SdkIpcSession()
        sdkIpc.unlockHandler = { userId in
            (try? SecretStore.read(userId: userId))
        }
        sdkIpc.authenticateHandler = {
            (try? SecretStore.requireAuthentication()) != nil
        }
        sdkIpc.availabilityHandler = {
            SecretStore.biometryAvailable()
        }
        sdkIpc.keyExistsHandler = {
            SecretStore.listUserIds().contains($0)
        }

        send(OutgoingMessage(command: "connected", appId: Logger.hostAppID))

        while true {
            let data: Data
            do {
                data = try NativeMessagingFrame.read(from: .standardInput)
            } catch {
                log.info("stdin 结束，host 退出：\(error)")
                return
            }
            log.info("收到消息：\(String(data: data, encoding: .utf8) ?? "<非 UTF-8>")")

            do {
                // 优先尝试新版 SDK IPC 信封（Noise_NN），否则走旧版命令协议
                if let ipcEnvelope = SdkIpcEnvelope.parse(data: data) {
                    let responses = try sdkIpc.handle(envelope: ipcEnvelope)
                    for response in responses {
                        sendRaw(try response.encoded())
                    }
                    continue
                }
                try handle(data, transportKey: transportKey)
            } catch {
                log.error("处理消息失败：\(error)")
            }
        }
    }

    private static func handle(_ data: Data, transportKey: Data) throws {
        let log = Logger.shared
        let decoder = JSONDecoder()

        // 明文消息：setupEncryption
        if let envelope = try? decoder.decode(Envelope<UnencryptedRequest>.self, from: data),
           envelope.message?.command == "setupEncryption" {
            let request = envelope.message!
            guard let publicKeyB64 = request.publicKey else {
                log.error("setupEncryption 缺少 publicKey")
                return
            }
            let publicKey = try BrowserCrypto.rsaPublicKey(fromSPKIBase64: publicKeyB64)
            let sharedSecret = try BrowserCrypto.encryptOAEPSHA1(
                publicKey: publicKey, message: transportKey)
            // messageId = -1 表示「这是一个新的桌面端会话」（与官方桌面端一致）
            send(OutgoingMessage(
                command: "setupEncryption",
                appId: envelope.appId,
                messageId: -1,
                sharedSecret: sharedSecret.base64EncodedString()))
            log.info("setupEncryption 完成（userId=\(request.userId ?? "-")）")
            return
        }

        // 加密消息
        if let envelope = try? decoder.decode(Envelope<EncryptedString>.self, from: data),
           let encrypted = envelope.message {
            let payloadData: Data
            do {
                payloadData = try BrowserCrypto.decryptStringSymmetric(
                    key: transportKey, encrypted: encrypted)
            } catch {
                // 通道解不开：让扩展重建会话
                log.error("解密失败，发送 invalidateEncryption：\(error)")
                send(OutgoingMessage(command: "invalidateEncryption", appId: envelope.appId))
                return
            }
            let payload = try decoder.decode(PayloadRequest.self, from: payloadData)

            // 时间戳校验（防重放），与官方桌面端一致
            if let timestamp = payload.timestamp {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                if abs(timestamp - now) > messageValidTimeoutMs {
                    log.info("消息时间戳过期（\(timestamp)），忽略")
                    return
                }
            }

            log.info("加密命令：\(payload.command)，userId=\(payload.userId ?? "-")，messageId=\(payload.messageId.map(String.init) ?? "-")")

            switch payload.command {
            case "unlockWithBiometricsForUser":
                try handleUnlock(payload, appId: envelope.appId, transportKey: transportKey)
            case "authenticateWithBiometrics":
                var passed = false
                do {
                    try SecretStore.requireAuthentication()
                    passed = true
                } catch {
                    Logger.shared.error("authenticateWithBiometrics 验证失败：\(error)")
                }
                sendEncrypted(StatusResponse(
                    command: "authenticateWithBiometrics",
                    messageId: payload.messageId ?? -1,
                    response: passed ? 1 : 0
                ), appId: envelope.appId, transportKey: transportKey)
                log.info("authenticateWithBiometrics 结果：\(passed)")
            case "getBiometricsStatus":
                sendEncrypted(StatusResponse(
                    command: "getBiometricsStatus",
                    messageId: payload.messageId ?? -1,
                    response: statusOverall()
                ), appId: envelope.appId, transportKey: transportKey)
            case "getBiometricsStatusForUser":
                sendEncrypted(StatusResponse(
                    command: "getBiometricsStatusForUser",
                    messageId: payload.messageId ?? -1,
                    response: statusForUser(payload.userId)
                ), appId: envelope.appId, transportKey: transportKey)
            default:
                log.info("未知加密命令：\(payload.command)，忽略")
            }
            return
        }

        log.error("无法解析的消息结构，忽略")
    }

    private static func statusOverall() -> Int {
        SecretStore.biometryAvailable()
            ? BiometricsStatusValue.available
            : BiometricsStatusValue.hardwareUnavailable
    }

    private static func statusForUser(_ userId: String?) -> Int {
        guard SecretStore.biometryAvailable() else {
            return BiometricsStatusValue.hardwareUnavailable
        }
        guard let userId = userId,
              SecretStore.listUserIds().contains(userId) else {
            return BiometricsStatusValue.notEnabledInConnectedDesktopApp
        }
        return BiometricsStatusValue.available
    }

    private static func handleUnlock(
        _ payload: PayloadRequest, appId: String?, transportKey: Data) throws {
        let log = Logger.shared
        guard let userId = payload.userId else {
            log.error("unlockWithBiometricsForUser 缺少 userId")
            let response = UnlockResponse(messageId: payload.messageId ?? -1, response: false)
            sendEncrypted(response, appId: appId, transportKey: transportKey)
            return
        }

        do {
            let keyB64 = try SecretStore.read(userId: userId)
            sendEncrypted(UnlockResponse(
                messageId: payload.messageId ?? -1,
                response: true,
                userKeyB64: keyB64
            ), appId: appId, transportKey: transportKey)
            log.info("解锁成功，已回传密钥（userId=\(userId)）")
        } catch {
            log.error("解锁失败：\(error)")
            sendEncrypted(UnlockResponse(
                messageId: payload.messageId ?? -1,
                response: false
            ), appId: appId, transportKey: transportKey)
        }
    }

    private static func sendEncrypted<T: Encodable>(
        _ payload: T, appId: String?, transportKey: Data) {
        do {
            let payloadData = try JSONEncoder().encode(payload)
            let encrypted = try BrowserCrypto.encryptStringSymmetric(
                transportKey: transportKey, plaintext: payloadData)
            send(OutgoingMessage(appId: appId, message: encrypted))
        } catch {
            Logger.shared.error("加密发送失败：\(error)")
        }
    }

    private static func send(_ message: OutgoingMessage) {
        do {
            let payload = try JSONEncoder().encode(message)
            Logger.shared.info("发送消息：\(String(data: payload, encoding: .utf8) ?? "?")")
            try NativeMessagingFrame.write(payload, to: .standardOutput)
        } catch {
            Logger.shared.error("发送消息失败：\(error)")
        }
    }

    /// 发送原始 JSON（SDK IPC 信封），不脱敏记录摘要
    private static func sendRaw(_ payload: Data) {
        do {
            Logger.shared.info("发送 SDK IPC 帧（\(payload.count) 字节）")
            try NativeMessagingFrame.write(payload, to: .standardOutput)
        } catch {
            Logger.shared.error("发送 SDK IPC 帧失败：\(error)")
        }
    }
}

/// 顶层消息信封，message 形态由调用方按需解码
private struct Envelope<T: Decodable>: Decodable {
    let appId: String?
    let message: T?
}
