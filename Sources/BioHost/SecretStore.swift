import Foundation
import LocalAuthentication
import Security

/// Keychain 密钥存储 + 读取前的生物识别验证。
/// 安全模型与参考实现（bw-bio-handler/goldwarden）一致：
/// 生物识别不是解密手段，而是读取密钥前的访问控制；
/// 密钥以本机专用条目（解锁后可读、不随 iCloud 同步）存放在登录钥匙串中。
enum SecretStore {
    enum SecretError: Error, CustomStringConvertible {
        case notFound
        case authFailed(String)
        case osStatus(OSStatus, String)

        var description: String {
            switch self {
            case .notFound:
                return "未找到该账户的密钥"
            case .authFailed(let why):
                return "身份验证未通过：\(why)"
            case .osStatus(let status, let context):
                return "Keychain 错误(\(status))：\(context) \(SecCopyErrorMessageString(status, nil) as String? ?? "")"
            }
        }
    }

    /// 写入密钥（已存在则覆盖）
    static func store(userId: String, keyB64: String) throws {
        // 同账户旧条目先删除，避免残留
        SecItemDelete(baseQuery(userId: userId) as CFDictionary)

        var query = baseQuery(userId: userId)
        query[kSecValueData as String] = Data(keyB64.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrLabel as String] = "Bitwarden 生物识别解锁密钥 (\(userId.prefix(8)))"

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretError.osStatus(status, "写入密钥失败")
        }
        Logger.shared.info("已存入账户 \(userId) 的密钥")
    }

    /// 读取密钥：先通过 Touch ID / 设备密码验证，再从 Keychain 取出
    static func read(userId: String) throws -> String {
        // 先无 UI 地确认条目存在，避免对未知账户也弹验证框
        var probe = baseQuery(userId: userId)
        probe[kSecReturnData as String] = false
        var probeResult: AnyObject?
        let probeStatus = SecItemCopyMatching(probe as CFDictionary, &probeResult)
        switch probeStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw SecretError.notFound
        default:
            throw SecretError.osStatus(probeStatus, "检查密钥失败")
        }

        try requireLocalAuthentication(reason: "Bitwarden 浏览器扩展请求解锁")

        var query = baseQuery(userId: userId)
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let keyB64 = String(data: data, encoding: .utf8) else {
                throw SecretError.osStatus(status, "密钥数据损坏")
            }
            Logger.shared.info("账户 \(userId) 密钥读取成功（已通过身份验证）")
            return keyB64
        case errSecItemNotFound:
            throw SecretError.notFound
        default:
            throw SecretError.osStatus(status, "读取密钥失败")
        }
    }

    static func listUserIds() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Logger.keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func remove(userId: String) {
        let status = SecItemDelete(baseQuery(userId: userId) as CFDictionary)
        Logger.shared.info("删除账户 \(userId) 密钥：status=\(status)")
    }

    /// 仅做身份验证（不读密钥），供 authenticateWithBiometrics 命令使用
    static func requireAuthentication() throws {
        try requireLocalAuthentication(reason: "Bitwarden 浏览器扩展请求身份验证")
    }

    /// Touch ID / 设备密码是否可用（用于 UI 提示）
    static func biometryAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: - 私有

    /// 阻塞式本地身份验证（Touch ID 失败回退设备密码）
    private static func requireLocalAuthentication(reason: String) throws {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = "使用密码"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw SecretError.authFailed(policyError?.localizedDescription ?? "此设备没有可用的验证方式")
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var selfSuccess = false
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if success {
                selfSuccess = true
            } else {
                policyError = error as NSError?
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard selfSuccess else {
            let message = policyError?.localizedDescription ?? "未知原因"
            Logger.shared.error("身份验证失败：\(message)")
            throw SecretError.authFailed(message)
        }
    }

    private static func baseQuery(userId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Logger.keychainService,
            kSecAttrAccount as String: userId,
        ]
    }
}
