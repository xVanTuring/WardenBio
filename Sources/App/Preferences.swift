import Foundation
import ServiceManagement

/// 入口显示偏好（UserDefaults 持久化）
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// 菜单栏图标开关；变更通过 onPresentationChanged 通知 AppDelegate 实时生效
    @Published var showInMenuBar: Bool {
        didSet {
            if oldValue != showInMenuBar {
                UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
                onPresentationChanged?()
            }
        }
    }

    var onPresentationChanged: (() -> Void)?

    private init() {
        showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true
    }
}

/// 包装 macOS 13+ 的 SMAppService 登录项 API
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("WardenBio: 登录项设置失败: \(error)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
