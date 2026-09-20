import AppKit
import SwiftUI

/// 唯一的主窗口：关闭只是隐藏，实例保留以便再次显示
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let size = CGSize(width: 540, height: 460)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "WardenBio"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView())
        window.setContentSize(Self.size)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 仅隐藏，App 继续驻留菜单栏
    }
}
