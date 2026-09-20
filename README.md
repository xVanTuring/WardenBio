# WardenBio

macOS 上的 Bitwarden 浏览器扩展「生物识别解锁」独立实现：不运行官方 Bitwarden 桌面客户端，仅用一个小型菜单栏 App + native messaging host，即可在浏览器扩展里用 **Touch ID / 设备密码** 解锁保险库。

协议参考 [quexten/bw-bio-handler](https://github.com/quexten/bw-bio-handler) 与 [quexten/goldwarden](https://github.com/quexten/goldwarden)（Bitwarden 桌面 ↔ 浏览器 IPC 协议的子集实现）。本项目非 Bitwarden 官方项目，相关解锁问题请勿反馈给 Bitwarden 团队。

## 工作原理

```
浏览器扩展 -stdio(native messaging)-> BioHost -> Touch ID 验证 -> 登录钥匙串
```

- 扩展与 host 之间的协议与官方桌面客户端一致：
  - `setupEncryption`：扩展发来 RSA 公钥，host 生成 32 字节传输密钥并用 RSA-OAEP-SHA1 加密返回
  - 之后的所有消息用 AES-256-CBC + PKCS7 加密；`message` 里必须同时给出 `encryptedString`（`2.<iv>|<data>|<mac>`）和 iv/data/mac——扩展解密只取 `encryptedString`，少了它会在扩展侧抛异常（表现为弹窗一直转圈）
  - `biometricUnlock`：扩展发起解锁，host 弹出 Touch ID（失败可回退设备密码），从钥匙串取出该账户的加密密钥加密返回
- 新版扩展还会另外开一条 native messaging 通道，走官方「桌面端 IPC」（本 host 顶替桌面端的 renderer 端点）：
  - 握手用 `Noise_NN_P256_AESGCM_SHA256`：Noise 帧封在 CBOR 里，传输载荷是 AES-256-GCM
  - 之后是 JSON RPC：`DiscoverRequest`（上报版本，扩展据此判断「桌面端已连接」）、`GetBiometricsStatus`、`UnlockBiometrics`（取密钥）、`AuthenticateBiometrics`（仅验证）
  - 应答必须用 `forwarded-bitwarden-ipc-message` 信封并带 `originalSource`，否则扩展会把来源记成 `DesktopMain` 而丢弃该帧
  - 扩展是否用这条通道做生物识别解锁取决于远端开关 `BiometricsSDKIPC`；关着时仍走上面的旧命令
- 账户加密密钥（即扩展需要的 biometric key）通过网页保险库控制台获取，录入时保存在登录钥匙串中（本机专用、解锁后可读、不 iCloud 同步）
- 安全模型与参考实现一致：生物识别是「读取密钥的访问控制」，不是解密手段；同一用户下的其他进程原则上可访问钥匙串（这在使用官方客户端时同样成立）

## 构建

依赖：Xcode、[xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
./scripts/build.sh            # Debug，默认
./scripts/build.sh Release    # Release
```

产物：`.build/derived/Build/Products/<配置>/WardenBio.app`（`BioHost` 已内嵌在 `Contents/MacOS/`）。

单元测试（含与 Go 参考实现的密码学互操作向量）：

```bash
xcodebuild -project WardenBio.xcodeproj -scheme WardenBio -derivedDataPath .build/derived test
```

## 使用步骤

1. **把 `WardenBio.app` 放到一个固定位置**（建议 `/Applications`）。manifest 会记录 host 的绝对路径，移动 app 后需重新安装 manifest。
2. 打开 app（菜单栏指纹图标 → 「打开 WardenBio…」），在 **浏览器** 标签页为你的浏览器点「安装」。支持 Chrome/Chromium/Edge/Brave/Vivaldi/Arc/Firefox。
3. 在已登录的 [Bitwarden 网页保险库](https://vault.bitwarden.com) 中按 F12 打开控制台，执行 app **密钥** 标签页里给出的两条命令，得到 User ID 与加密密钥（`encKeyB64`）。
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

## 目录结构

```
project.yml               xcodegen 工程定义
Sources/Protocol/         协议：帧编解码、消息模型、AES-CBC、SPKI/OAEP
Sources/BioHost/          native messaging host（serve/store-key/list-keys/remove-key/test-unlock）
Sources/App/              菜单栏 App（SwiftUI：浏览器管理/密钥录入/日志）
Sources/Shared/           两个目标共用的工具（日志）
Tests/ProtocolTests/      协议单元测试（含 Go 参考实现互操作向量）
scripts/build.sh          xcodegen generate + xcodebuild 一键构建
reference/                参考实现源码（bw-bio-handler、goldwarden）
```
