import Foundation
import SwiftUI

/// 共享 UI 状态
final class AppState: ObservableObject {
    @Published var targets: [BrowserTarget] = BrowserManager.defaultTargets()
    @Published var storedUserIds: [String] = []
    @Published var logText: String = ""
    @Published var statusMessage: String = ""
    @Published var isBusy = false

    init() {
        reload()
    }

    func reload() {
        targets = BrowserManager.defaultTargets()
        storedUserIds = (try? BioHostBridge.run("list-keys"))?.stdout
            .split(separator: "\n").map(String.init) ?? []
        loadLog()
    }

    func loadLog() {
        let url = Logger.shared.logFileURL
        logText = (try? String(contentsOf: url, encoding: .utf8)) ?? "暂无日志"
    }

    /// 保存密钥并立即验证（触发 Touch ID）
    func saveKey(userId: String, keyB64: String) {
        isBusy = true
        statusMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let store = try BioHostBridge.run("store-key", stdin: "\(userId)\n\(keyB64)\n")
                guard store.exitCode == 0 else {
                    throw BridgeFailure(message: store.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let test = try BioHostBridge.run("test-unlock", arguments: [userId])
                DispatchQueue.main.async {
                    self.isBusy = false
                    if test.exitCode == 0 {
                        self.statusMessage = "密钥已保存，Touch ID 验证通过"
                        self.reload()
                    } else {
                        self.statusMessage = "密钥已保存，但验证未通过：\(test.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                        self.reload()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = "保存失败：\(error)"
                }
            }
        }
    }

    func testUnlock(userId: String) {
        isBusy = true
        statusMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = (try? BioHostBridge.run("test-unlock", arguments: [userId])) ??
                (exitCode: 1, stdout: "", stderr: "调用失败")
            DispatchQueue.main.async {
                self.isBusy = false
                self.statusMessage = result.exitCode == 0
                    ? "验证通过"
                    : "验证失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    func removeKey(userId: String) {
        _ = try? BioHostBridge.run("remove-key", arguments: [userId])
        reload()
    }

    struct BridgeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
