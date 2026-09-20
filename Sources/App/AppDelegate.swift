import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 第二个实例启动时（见 main.swift）通知本实例显示窗口
    static let showWindowNotification = Notification.Name("com.xvan.WardenBio.showWindow")

    private var windowController: MainWindowController!
    private var statusItemController: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.buildMainMenu()
    }

    /// accessory 应用也需要主菜单承接 ⌘C/⌘V/⌘X/⌘A 等编辑快捷键
    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MainWindowController()
        applyPresentation()
        Preferences.shared.onPresentationChanged = { [weak self] in self?.applyPresentation() }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindow),
            name: Self.showWindowNotification, object: nil)

        // 登录项自动启动时保持安静，只驻留菜单栏
        if !LaunchContext.launchedAsLoginItem {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showWindow() {
        windowController.show()
    }

    /// 按偏好设置显隐菜单栏入口
    private func applyPresentation() {
        if Preferences.shared.showInMenuBar {
            if statusItemController == nil {
                statusItemController = StatusItemController { [weak self] in self?.showWindow() }
            }
            refreshStateLine()
        } else {
            statusItemController = nil
        }
    }

    func refreshStateLine() {
        let installed = BrowserManager.defaultTargets().filter(\.isInstalled).count
        let keys = (try? BioHostBridge.run("list-keys"))?.stdout
            .split(separator: "\n").count ?? 0
        statusItemController?.refreshStateLine(installedManifests: installed, storedKeys: keys)
    }

    private enum LaunchContext {
        static var launchedAsLoginItem: Bool {
            guard let event = NSAppleEventManager.shared().currentAppleEvent,
                  event.eventClass == AEEventClass(kCoreEventClass),
                  event.eventID == AEEventID(kAEOpenApplication),
                  let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
            else { return false }
            return prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }
}
