import SwiftUI

struct ContentView: View {
    @ObservedObject var state = AppState()

    var body: some View {
        TabView {
            BrowserTab(state: state)
                .tabItem { Label("浏览器", systemImage: "globe") }
            KeyTab(state: state)
                .tabItem { Label("密钥", systemImage: "key") }
            SettingsTab()
                .tabItem { Label("设置", systemImage: "switch.2") }
            LogTab(state: state)
                .tabItem { Label("日志", systemImage: "doc.text") }
        }
        .frame(width: MainWindowController.size.width, height: MainWindowController.size.height)
    }
}

// MARK: - 浏览器 manifest 管理

struct BrowserTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(state.targets) { target in
                    HStack {
                        Image(systemName: target.isFirefoxLike ? "sparkles" : "safari")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(target.name).font(.headline)
                            Text(target.isInstalled
                                 ? (BrowserManager.isOwnedByUs(target) ? "已配置（WardenBio）" : "已存在（可能是官方桌面客户端的配置）")
                                 : "未配置")
                                .font(.caption)
                                .foregroundStyle(target.isInstalled ? .green : .secondary)
                        }
                        Spacer()
                        if target.isInstalled {
                            Button("卸载") {
                                BrowserManager.uninstall(from: target)
                                state.reload()
                                (NSApp.delegate as? AppDelegate)?.refreshStateLine()
                            }
                        }
                        Button("安装") {
                            try? BrowserManager.install(to: target)
                            state.reload()
                            (NSApp.delegate as? AppDelegate)?.refreshStateLine()
                        }
                    }
                }
            }
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
    }
}

// MARK: - 密钥录入与验证

struct KeyTab: View {
    @ObservedObject var state: AppState
    @State private var userId = ""
    @State private var encKey = ""

    private let snippetExtract = """
    chrome.storage.session.get(null, d => {
      for (const [k, v] of Object.entries(d)) {
        const m = k.match(/^user_([^_]+)_crypto_userKey$/);
        if (m) {
          const inner = JSON.parse(v.value ?? "{}");
          const entry = inner[""] ?? Object.values(inner)[0];
          console.log(JSON.stringify({ userId: m[1], keyB64: entry.keyB64 }));
        }
      }
    });
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("第一步：在已解锁的浏览器扩展里取出两个值")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 浏览器扩展需处于已解锁状态").font(.caption)
                        Text("2. 打开扩展的后台控制台：chrome://extensions → 开发者模式 → Bitwarden → 「服务工作进程」；Firefox 用 about:debugging → 「检查」")
                            .font(.caption)
                        Text("3. 在弹出的控制台里粘贴运行下面这段代码，复制输出的 JSON").font(.caption)
                        snippetRow(snippetExtract, label: "提取脚本")
                        Text("输出包含 User ID 和加密密钥（keyB64），只保存在本机钥匙串，请勿外传。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox(label: Text("第二步：保存到本机（Keychain + Touch ID 保护）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("User ID", text: $userId)
                            .textFieldStyle(.roundedBorder)
                        SecureField("加密密钥 (base64)", text: $encKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("保存并验证") {
                                state.saveKey(userId: userId.trimmingCharacters(in: .whitespaces),
                                              keyB64: encKey.trimmingCharacters(in: .whitespaces))
                            }
                            .disabled(userId.isEmpty || encKey.isEmpty || state.isBusy)
                            if state.isBusy { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(4)
                }

                GroupBox(label: Text("已保存的账户")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.storedUserIds.isEmpty {
                            Text("暂无").foregroundStyle(.secondary).font(.caption)
                        }
                        ForEach(state.storedUserIds, id: \.self) { id in
                            HStack {
                                Text(id).font(.caption.monospaced()).lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("测试解锁") { state.testUnlock(userId: id) }
                                Button("删除", role: .destructive) { state.removeKey(userId: id) }
                            }
                        }
                    }
                    .padding(4)
                }

                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }

    private func snippetRow(_ snippet: String, label: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.bold()).frame(width: 140, alignment: .leading)
            Text(snippet)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet, forType: .string) }
        }
    }
}

// MARK: - 设置（可控入口）

struct SettingsTab: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.requiresApproval

    var body: some View {
        Form {
            Section("入口") {
                Toggle("在菜单栏显示图标", isOn: $prefs.showInMenuBar)
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(newValue)
                        needsApproval = LaunchAtLogin.requiresApproval
                    }
                if needsApproval {
                    HStack {
                        Text("需要在系统设置中批准登录项")
                            .font(.caption).foregroundStyle(.orange)
                        Button("打开系统设置") { LaunchAtLogin.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }
            Section("说明") {
                Text("菜单栏图标只是配置入口；解锁时由浏览器直接拉起内置的 BioHost，本 App 无需常驻运行。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("manifest 记录的是当前 app 的绝对路径；移动 WardenBio.app 位置后需在「浏览器」页重新安装。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(0)
    }
}

// MARK: - 日志

struct LogTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(state.logText)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button("刷新") { state.loadLog() }
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([Logger.shared.logFileURL])
                }
                Spacer()
            }
            .padding([.horizontal, .bottom], 8)
        }
    }
}
