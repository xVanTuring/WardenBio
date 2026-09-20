import Foundation

/// host 日志：写到 ~/Library/Application Support/WardenBio/host.log，敏感字段脱敏
final class Logger {
    static let shared = Logger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "tech.xvanturing.wardenbio.logger")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WardenBio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("host.log")
    }

    static let keychainService = "com.8bit.bitwarden.biobridge"
    static let hostAppID = "tech.xvanturing.wardenbio"

    func info(_ message: String) {
        write(level: "INFO", message: redact(message))
    }

    func error(_ message: String) {
        write(level: "ERROR", message: redact(message))
    }

    var logFileURL: URL { fileURL }

    /// 把 base64 长串（密钥/密文）替换为占位符
    private func redact(_ message: String) -> String {
        var result = message
        for pattern in ["keyB64\":\"", "data\":\"", "sharedSecret\":\"", "publicKey\":\"",
                        "encryptedString\":\""] {
            guard let range = result.range(of: pattern) else { continue }
            let end = result[range.upperBound...].firstIndex(of: "\"") ?? range.upperBound
            result.replaceSubrange(range.lowerBound..<end, with: "\(pattern)<redacted>")
        }
        return result
    }

    private func write(level: String, message: String) {
        queue.sync {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
