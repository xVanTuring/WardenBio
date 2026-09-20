import AppKit

/// 菜单栏入口：状态行 + 打开窗口 + 退出，图标按配置显隐
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let onShowWindow: () -> Void
    private let stateLine = NSMenuItem()

    init(onShowWindow: @escaping () -> Void) {
        self.onShowWindow = onShowWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开 WardenBio…", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 WardenBio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        renderIcon()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 刷新状态行（浏览器 manifest 数 / 已存密钥数）
    func refreshStateLine(installedManifests: Int, storedKeys: Int) {
        stateLine.title = "已配置 \(installedManifests) 个浏览器 · 已存 \(storedKeys) 个密钥"
    }

    private func renderIcon() {
        let image = NSImage(systemSymbolName: "touchid", accessibilityDescription: "WardenBio")
        image?.isTemplate = true
        statusItem.button?.image = image ?? nil
        if statusItem.button?.image == nil {
            statusItem.button?.title = "指纹"
        }
    }

    @objc private func openWindow() {
        onShowWindow()
    }
}
