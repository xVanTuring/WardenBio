# WardenBio — agent 说明

macOS 上的 Bitwarden 浏览器扩展「生物识别解锁」独立实现：一个菜单栏 App
（配置界面）+ 内嵌的 native messaging host（`BioHost`，真正干活的进程）。

面向使用者的文档在 [`README.md`](./README.md)（英文）/ [`README.zh-CN.md`](./README.zh-CN.md)（中文）里；
这里只写改代码时需要知道的约定。

## 构建与运行

```bash
./scripts/build.sh            # Debug，默认
./scripts/build.sh Release    # Release
# 产物：.build/derived/Build/Products/<配置>/WardenBio.app（BioHost 内嵌在 Contents/MacOS/）

# 单元测试（改协议、改密码学后必跑）
xcodebuild -project WardenBio.xcodeproj -scheme WardenBio -derivedDataPath .build/derived test

# 单独跑 host（不必经过浏览器）
BIN=.build/derived/Build/Products/Debug/WardenBio.app/Contents/MacOS/BioHost
"$BIN" list-keys
"$BIN" test-unlock <userId>              # 会弹 Touch ID
"$BIN"                                  # 无参数 = serve：从 stdin 读 4 字节小端长度帧
```

`WardenBio.xcodeproj` 是 xcodegen 产物（已 gitignore）；改文件结构或 `project.yml` 后要重新 `xcodegen generate`。
`Sources/App/Info.plist` 由 `project.yml` 的 `info.properties` 生成，**版本号不要在 Info.plist 里手改**（会被覆盖），
发布时由 `scripts/release.sh` 统一改。

host 日志：`~/Library/Application Support/WardenBio/host.log`（长串密钥已脱敏）。

应用图标的源文件是 `Sources/App/Resources/AppIcon.svg`；改完跑 `./scripts/make-icon.sh` 重新光栅化成
`Sources/App/Resources/Assets.xcassets/AppIcon.appiconset`（需要 `brew install librsvg`）。
生成的 PNG 入库，所以打包链路本身不依赖 rsvg-convert。

## 源码布局

```
Sources/Protocol/   协议层（App / BioHost / 测试三方共用，必须保持无 UI 依赖）
  NativeMessagingFrame.swift   stdio 帧：4 字节本机字节序长度 + JSON
  Messages.swift               旧版命令协议的消息模型（EcnryptedString/OutgoingMessage/…）
  BrowserCrypto.swift          传输密钥、AES-256-CBC+HMAC、SPKI 解析、RSA-OAEP-SHA1
  NoiseNN.swift                Noise_NN_P256_AESGCM_SHA256 的响应方（对齐 Rust snow 0.10）
  Cbor.swift                   CBOR 子集（对齐 ciborium + serde 语义）
  SdkIpc.swift                 新版「桌面端 IPC」会话层：握手帧、传输帧、JSON RPC 分发
Sources/BioHost/    host 进程：main.swift（子命令）+ Serve.swift（serve 主循环）+ SecretStore.swift（钥匙串 + Touch ID）
Sources/App/        菜单栏 App（SwiftUI 四个页签 + AppDelegate/StatusItem + 登录项）
Sources/Shared/     共用工具（Logger）
Tests/ProtocolTests/ 协议单元测试
```

## 两条通道（改协议时最容易踩的地方）

浏览器扩展会**同时**开两条 native messaging 连接（两个 host 进程）：

1. **旧版命令协议**（一直是主路径）：`setupEncryption` 用 RSA-OAEP-SHA1 换 64 字节传输密钥，
   之后 AES-256-CBC + HMAC-SHA256。见 `Serve.swift` 的 `handle(_:transportKey:)`。
   - `message` 必须同时给 `encryptedString`（`"2.<iv>|<data>|<mac>"`）和 iv/data/mac：
     扩展解密走 `PureCrypto.symmetric_decrypt_string(encString.encryptedString, key)`，
     少了 `encryptedString` 会在扩展侧抛异常、弹窗一直转圈（现象很像"卡住"）。
   - 应答带上 `appId`（原样回传）和 `messageId`（对应请求），扩展按 messageId 匹配回调。
2. **新版桌面端 IPC**（较新扩展才用，本 host 顶替 renderer 端点）：Noise 握手 + CBOR 帧 +
   JSON RPC。见 `SdkIpc.swift` / `NoiseNN.swift`。
   - 应答信封必须是 `forwarded-bitwarden-ipc-message` 且带 `originalSource`：
     扩展对普通信封一律把来源记成 `DesktopMain`，发起方会以"来源 ≠ 目标端点"丢弃该帧
     （表现为 `RequestError: Failed to send message: Timeout`）。
   - 扩展是否用这条通道做生物识别解锁取决于远端开关 `BiometricsSDKIPC`；关着时仍走旧命令。
   - Noise 细节必须对齐 snow，四处都踩过：`h` 初值 = `SHA256(补零的协议名)`（含空 prologue 的 MixHash），
     `ck` 初值 = 补零的协议名；msg1 的空载荷也要 MixHash；`MixKey` 要更新 `ck`；
     `Split` 用 `ck`、握手载荷 AEAD 的 AAD 取当前握手哈希；传输帧 nonce 从 1 开始、4 零字节 + u64 大端。
   - RPC 报文对齐 sdk-internal `0.2.0-main.950`：请求 topic `RpcRequestMessage`、应答 topic
     `RpcResponseMessage`；`result` 是 `Result` 的外部标签形式（`{"Ok":…}` / `{"Err":"NoHandlerFound"}`）；
     `user_key` 是 base64 字符串。

## 验证手段

改协议/密码学后，除了单元测试，还有一套用**扩展自带 SDK wasm**跑的端到端 harness
（在 `.build/bw-harness/`，`.build` 已 gitignore；用 rust + snow 做过交叉验证）：

```bash
cd .build/bw-harness
node harness.mjs /Applications/WardenBio.app/Contents/MacOS/BioHost          # 不弹 Touch ID
node harness.mjs <BioHost 路径> --ui                                        # 会弹 Touch ID（4 次以内）
# snow 侧的握手对照（真发起方 + 本仓库响应方）：
#   cd oracle && cargo run -- /tmp/bw-harness/swift-responder
```

harness 用的是从本机已装 Chrome 扩展里抽出来的 `bitwarden_wasm_internal_bg.js`（background.js.map
的 `sourcesContent[1]`）和 `63ba*.module.wasm`；扩展升级后要重新抽一次。

改动生效的位置：manifest 记的是 `/Applications/WardenBio.app/Contents/MacOS/BioHost`
的绝对路径，所以要 `cp -R` 到 `/Applications` 后再测；换完记得 `pkill -f "Mozilla/NativeMessagingHosts/com.8bit.bitwarden.json"`
把旧 host 进程结束掉，浏览器会在下一次连接时拉起新进程（扩展侧的传输层在握手失败后不会自己重试）。

## 发布

一次性准备（本机已具备 Developer ID 证书：`Developer ID Application: … (T8F5T6HKG8)`）：

```bash
# 公证凭据（Apple ID + App 专用密码），只在第一次需要
xcrun notarytool store-credentials wardenbio-notary \
    --apple-id <Apple ID> --team-id T8F5T6HKG8 --password <App 专用密码>
# 同一 Apple 账号下已有别名的 profile 时可以直接复用：
#   NOTARY_PROFILE=noticky-notary ./scripts/release.sh 0.1.0
```

本地一条链发版：

```bash
./scripts/release.sh 0.1.0                    # 改版本 → 测试 → 提交推送 → 归档 → Developer ID 重签
                                              # → 公证 .app → staple → zip/dmg → 公证 dmg → staple
                                              # → SHA256SUMS → 打 tag → gh release create
./scripts/release.sh 0.1.0 --prerelease beta   # 预发布 tag（v0.1.0-beta）
./scripts/release.sh 0.1.0 --dry-run           # 只改版本 + 跑测试 + 本地提交
./scripts/release.sh --package-only            # 不碰 git、不公证，只产出 dist/ 里的包（验证打包链路用）
```

- 版本号只有一处来源：`project.yml` 的 `CFBundleShortVersionString` / `CFBundleVersion`（脚本自增 build）。
- WardenBio **不需要** provisioning profile（没有 entitlements），所以 `scripts/ExportOptions.plist` 里没有
  `provisioningProfiles` 段；将来加了 App Group / iCloud 之类的 entitlement 才需要补（参考 Perch）。
- `project.yml` 里 BioHost 的 `SKIP_INSTALL: YES` **不能删**：BioHost 已经内嵌进 app bundle，
  它再作为独立产物进归档的话，Xcode 判不出该分发哪个产物，就不写 `ApplicationProperties`，
  随后 `-exportArchive` 会报 `method ... expected one {}`。两个打包脚本都会提前检查这一项。
- CI 上只导入了 Developer ID 证书（没有 Apple Development），所以 `scripts/ci/package_and_publish.sh`
  归档时在命令行覆盖 `CODE_SIGN_STYLE=Manual` / `CODE_SIGN_IDENTITY="Developer ID Application"`；
  本地脚本则照常用 project.yml 的默认设置归档，再由 `-exportArchive` 重签。
- 发布说明：`--notes-file` > `release-notes/<tag>.md` > 按上个 tag 之后的提交自动生成。
  可以写双语，用 `<!-- lang:en -->` / `<!-- lang:zh -->` 分段——GitHub 上这些注释不可见，正文就是双语堆叠。
  模板见 `release-notes/TEMPLATE.md`，复制成 `release-notes/v<版本>.md` 填即可。
- tag 触发 GitHub Actions 走同一条链路（`scripts/ci/package_and_publish.sh`），需要的 secrets：
  `DEVELOPER_ID_APP_CERT_P12`、`DEVELOPER_ID_APP_CERT_PASSWORD`、`KEYCHAIN_PASSWORD`、
  `APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`。

发完的冒烟清单（脚本结束时也会打一遍）：装 dmg → 拖进 /Applications → 启动 → 浏览器页「安装」→
密钥页录入 → 扩展里解锁验证 Touch ID。注意从自编译版本（Apple Development 签名）换到正式版
（Developer ID 签名）后，钥匙串里旧条目可能读不出来，重新录入即可。

## 约定

- 一个完整改动 = 一个提交；**提交前要用户明确同意**，不要自己 push、不要做破坏性 git 操作。
- 提交信息用中文，说明动机而不是复述 diff；版本提交统一为 `release: bump to <version> (build <n>)`。
- 注释只写「为什么」，别复述代码；协议里的坑（上面那几条）值得留注释，因为它们从代码看不出来。
- `reference/` 是独立 clone 的参考实现，已在 `.gitignore` 里，不要加进版本库。
