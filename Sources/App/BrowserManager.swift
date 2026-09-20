import Foundation

/// 浏览器检测与 native messaging manifest 安装管理
struct BrowserTarget: Identifiable {
    let id = UUID()
    let name: String
    /// manifest 所在目录（相对 ~/Library/Application Support）
    let relativeDir: String
    let isFirefoxLike: Bool

    var manifestDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativeDir, isDirectory: true)
    }

    var manifestURL: URL {
        manifestDir.appendingPathComponent("com.8bit.bitwarden.json")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: manifestURL.path)
    }
}

enum BrowserManager {
    static let hostName = "com.8bit.bitwarden"

    /// Chrome 系扩展 ID（正式版 + 常见分发渠道）
    static let chromeExtensionOrigins = [
        "chrome-extension://nngceckbapebfimnlniiiahkandclblb/",
        "chrome-extension://jbkfoedolllekgbhcbcoahefnbanhhlh/",
        "chrome-extension://ccnckbpmaceehanjmeomladnmlffdjgn/",
    ]

    /// Firefox 系扩展 ID（官方 + goldwarden 所用）
    static let firefoxExtensionIDs = [
        "{446900e4-71c0-4175-9ddd-d673b6bec2a2}",
        "{446900e4-71c2-419f-a6a7-df9c091e268b}",
    ]

    static func defaultTargets() -> [BrowserTarget] {
        [
            BrowserTarget(name: "Chrome", relativeDir: "Google/Chrome/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Chromium", relativeDir: "Chromium/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Microsoft Edge", relativeDir: "Microsoft Edge/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Brave", relativeDir: "BraveSoftware/Brave-Browser/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Vivaldi", relativeDir: "Vivaldi/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Arc", relativeDir: "Arc/User Data/NativeMessagingHosts", isFirefoxLike: false),
            BrowserTarget(name: "Firefox", relativeDir: "Mozilla/NativeMessagingHosts", isFirefoxLike: true),
        ]
    }

    static func manifestContent(for target: BrowserTarget) throws -> String {
        guard let hostURL = BioHostBridge.hostURL() else {
            throw ManagerError.hostMissing
        }
        let path = hostURL.path
        if target.isFirefoxLike {
            let ids = firefoxExtensionIDs.map { "    \"\($0)\"" }.joined(separator: ",\n")
            return """
            {
              "name": "\(hostName)",
              "description": "WardenBio: Bitwarden browser biometrics via Touch ID",
              "path": "\(path)",
              "type": "stdio",
              "allowed_extensions": [
            \(ids)
              ]
            }
            """
        } else {
            let origins = chromeExtensionOrigins.map { "    \"\($0)\"" }.joined(separator: ",\n")
            return """
            {
              "name": "\(hostName)",
              "description": "WardenBio: Bitwarden browser biometrics via Touch ID",
              "path": "\(path)",
              "type": "stdio",
              "allowed_origins": [
            \(origins)
              ]
            }
            """
        }
    }

    static func install(to target: BrowserTarget) throws {
        let dir = target.manifestDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifestContent(for: target).write(to: target.manifestURL, atomically: true, encoding: .utf8)
    }

    static func uninstall(from target: BrowserTarget) {
        try? FileManager.default.removeItem(at: target.manifestURL)
    }

    /// 检测 manifest 指向的 host 是否为本 app（用于提示覆盖官方桌面客户端的配置）
    static func isOwnedByUs(_ target: BrowserTarget) -> Bool {
        guard let content = try? String(contentsOf: target.manifestURL, encoding: .utf8),
              let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String else { return false }
        return path.contains("WardenBio.app")
    }

    enum ManagerError: Error, CustomStringConvertible {
        case hostMissing

        var description: String {
            switch self {
            case .hostMissing:
                return "未找到 BioHost，请确认 app 完整"
            }
        }
    }
}
