# WardenBio

[English](./README.md) · 简体中文

> macOS 上的 Bitwarden 浏览器扩展「生物识别解锁」独立实现 —— 不装官方桌面客户端，用一个菜单栏 App 顶替它，用 Touch ID / 设备密码解锁保险库。

WardenBio 自带一个 native messaging host（`BioHost`，内嵌在 app 里，由浏览器按需拉起）。
在浏览器扩展眼里它就是桌面端：扩展发起生物识别解锁时，它先做一次 Touch ID（失败可回退设备密码）
验证，再从登录钥匙串里取出该账户的加密密钥回传。

协议参考 [quexten/bw-bio-handler](https://github.com/quexten/bw-bio-handler) 与
[quexten/goldwarden](https://github.com/quexten/goldwarden)（Bitwarden 桌面 ↔ 浏览器 IPC 协议的子集实现）。
本项目非 Bitwarden 官方项目，相关解锁问题请勿反馈给 Bitwarden 团队。

## 安装

1. 从本仓库 Releases 页下载 `WardenBio-<版本>.dmg`
2. 打开 dmg，把 `WardenBio.app` 拖进 `/Applications`
   —— manifest 里记的是 host 的绝对路径，**换位置后要在 app 里重新「安装」一次**
3. 启动 app，按下面「使用步骤」配置

要求 macOS 14+，以及一台支持 Touch ID 的 Mac（或者是已设置设备密码的 Mac）。

## 工作原理

```
浏览器扩展 -stdio(native messaging)-> BioHost -> Touch ID 验证 -> 登录钥匙串
```

- 扩展与 host 之间的协议与官方桌面客户端一致：
  - `setupEncryption`：扩展发来 RSA 公钥，host 生成 64 字节传输密钥并用 RSA-OAEP-SHA1 加密返回
  - 之后的所有消息用 AES-256-CBC + PKCS7 加密；`message` 里必须同时给出 `encryptedString`（`2.<iv>|<data>|<mac>`）和 iv/data/mac——扩展解密只取 `encryptedString`，少了它会在扩展侧抛异常（表现为弹窗一直转圈）
  - `unlockWithBiometricsForUser`：扩展发起解锁，host 弹出 Touch ID，从钥匙串取出该账户的加密密钥加密返回
- 新版扩展还会另外开一条 native messaging 通道，走官方「桌面端 IPC」（本 host 顶替桌面端的 renderer 端点）：
  - 握手用 `Noise_NN_P256_AESGCM_SHA256`：Noise 帧封在 CBOR 里，传输载荷是 AES-256-GCM
  - 之后是 JSON RPC：`DiscoverRequest`（上报版本，扩展据此判断「桌面端已连接」）、`GetBiometricsStatus`、`UnlockBiometrics`（取密钥）、`AuthenticateBiometrics`（仅验证）
  - 应答必须用 `forwarded-bitwarden-ipc-message` 信封并带 `originalSource`，否则扩展会把来源记成 `DesktopMain` 而丢弃该帧
  - 扩展是否用这条通道做生物识别解锁取决于远端开关 `BiometricsSDKIPC`；关着时仍走上面的旧命令
- 账户加密密钥（即扩展需要的 biometric key）从已解锁的浏览器扩展里取出，录入时保存在登录钥匙串中（本机专用、解锁后可读、不 iCloud 同步）
- 安全模型与参考实现一致：生物识别是「读取密钥的访问控制」，不是解密手段；同一用户下的其他进程原则上可访问钥匙串（这在使用官方客户端时同样成立）

## 使用步骤

1. **把 `WardenBio.app` 放在固定位置**（建议 `/Applications`）。manifest 会记录 host 的绝对路径，移动 app 后需重新安装 manifest。
2. 打开 app（菜单栏指纹图标 → 「打开 WardenBio…」），在 **浏览器** 标签页为你的浏览器点「安装」。支持 Chrome/Chromium/Edge/Brave/Vivaldi/Arc/Firefox。
3. 在 app **密钥** 标签页点「复制提取脚本」，把脚本粘贴到浏览器扩展的后台控制台（Chrome：`chrome://extensions` → 开发者模式 → Bitwarden → 「服务工作进程」；Firefox：`about:debugging` → 「检查」）回车运行，得到 User ID 与加密密钥（`keyB64`）。
4. 回到 app **密钥** 标签页，粘贴两个值 → 「保存并验证」→ 按 Touch ID。验证通过即录入完成。
5. 在浏览器 Bitwarden 扩展的 设置 → 账户安全 中开启「使用生物识别解锁浏览器」。之后锁定扩展再点击解锁，会弹出 Touch ID。

## 卸载

- App **浏览器** 标签页：对每个已配置的浏览器点「卸载」（删除 `com.8bit.bitwarden.json`）
- App **密钥** 标签页：删除各账户密钥
- 退出并删除 WardenBio.app

## 已知限制

- 不支持 Safari（其扩展机制与 native messaging 不同）
- 浏览器需以常规方式安装；如果浏览器无法看到 `~/Library/Application Support` 下的 manifest（如特殊的沙盒/便携版配置），解锁会静默失败
- host 进程由浏览器在扩展开启生物识别后按需拉起，app 本身不需要常驻运行（仅管理时打开）
- 录入的密钥等同于保险库的加密密钥，请勿在任何地方明文留存
- 从自编译版本（Apple Development 签名）换成正式版（Developer ID 签名）后，钥匙串里的旧条目可能读不出来，重新录入一次即可

## 从源码构建

依赖：Xcode、[xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
./scripts/build.sh            # Debug，默认
./scripts/build.sh Release    # Release
```

产物：`.build/derived/Build/Products/<配置>/WardenBio.app`（`BioHost` 已内嵌在 `Contents/MacOS/`）。

单元测试（含与 Go 参考实现的密码学互操作向量、以及 snow 验证过的 Noise 握手向量）：

```bash
xcodebuild -project WardenBio.xcodeproj -scheme WardenBio -derivedDataPath .build/derived test
```

## 发布（维护者）

```bash
./scripts/release.sh 0.1.0                    # 改版本 → 测试 → 提交推送 → 归档签名 → 公证 → 打包 → 打 tag → 建 Release
./scripts/release.sh 0.2.0 --prerelease beta  # 预发布
./scripts/release.sh 0.2.0 --dry-run          # 只改版本 + 跑测试 + 本地提交
./scripts/release.sh --package-only           # 不碰 git、不公证，只产出 dist/ 下的包
```

发版只在本机做，没有云端打包：公证需要 Developer ID 私钥和 Apple 凭据，搬进 CI 不划算。
一次性准备与细节见 [AGENTS.md](./AGENTS.md) 的「发布」一节。

## 目录结构

```
project.yml                    xcodegen 工程定义
Sources/Protocol/              协议：帧编解码、消息模型、AES-CBC/HMAC、SPKI/OAEP、Noise、CBOR
Sources/BioHost/               native messaging host（serve/store-key/list-keys/remove-key/test-unlock）
Sources/App/                   菜单栏 App（SwiftUI：浏览器管理/密钥录入/设置/日志）
Sources/Shared/                各目标共用的工具（日志）
Tests/ProtocolTests/           协议单元测试（Go 参考实现互操作向量 + 握手向量）
scripts/build.sh               xcodegen generate + xcodebuild 一键构建
scripts/release.sh             本地发布全流程
scripts/make-icon.sh           把 AppIcon.svg 光栅化进资产目录
scripts/ExportOptions.plist    Developer ID 导出选项
reference/                     参考实现源码（bw-bio-handler、goldwarden，独立 clone，不入库）
```
