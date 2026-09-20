import AppKit

// 单实例：已有副本运行时，通知它显示窗口后退出
let myPID = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "tech.xvanturing.WardenBio"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != myPID }
if let other = others.first {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    other.activate(options: [])
    usleep(200_000)
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
