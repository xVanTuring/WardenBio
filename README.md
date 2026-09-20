# WardenBio

English · [简体中文](./README.zh-CN.md)

> Native biometric unlock for the Bitwarden browser extension on macOS — no Bitwarden Desktop app required. A tiny menu-bar app stands in for the desktop client and guards the key with Touch ID / device password.

WardenBio ships its own native messaging host (`BioHost`, embedded in the app and launched by
the browser on demand). As far as the browser extension is concerned, it *is* the desktop client:
when the extension asks for a biometric unlock, it performs a Touch ID check (falling back to the
device password), then reads that account's encryption key from the login keychain and hands it
back — encrypted, on the channel the extension set up.

The protocol follows [quexten/bw-bio-handler](https://github.com/quexten/bw-bio-handler) and
[quexten/goldwarden](https://github.com/quexten/goldwarden) (a subset of the Bitwarden
Desktop ↔ browser IPC protocol). This is not an official Bitwarden project — please don't report
unlock problems here to the Bitwarden team.

## Installation

1. Download `WardenBio-<version>.dmg` from this repository's Releases page
2. Open the dmg and drag `WardenBio.app` into `/Applications`
   — the native messaging manifest stores the host's absolute path, so **if you move the app,
   install the manifest again** from inside the app
3. Launch the app and follow "Usage" below

Requires macOS 14+ and a Mac with Touch ID (or one with a device password configured).

## How it works

```
browser extension -stdio(native messaging)-> BioHost -> Touch ID -> login keychain
```

- The extension ↔ host protocol matches the official desktop client:
  - `setupEncryption`: the extension sends an RSA public key; the host generates a 64-byte
    transport key and returns it encrypted with RSA-OAEP-SHA1
  - everything after that is AES-256-CBC + PKCS7; each `message` must carry both
    `encryptedString` (`2.<iv>|<data>|<mac>`) and iv/data/mac — the extension decrypts using
    `encryptedString` only, and without it the extension throws and its popup spins forever
  - `unlockWithBiometricsForUser`: the extension asks for an unlock, the host shows Touch ID and
    returns the account's encryption key
- Newer extensions open a *second* native messaging channel speaking the official "desktop IPC"
  (the host impersonates the desktop renderer endpoint):
  - handshake: `Noise_NN_P256_AESGCM_SHA256` — Noise frames wrapped in CBOR, payloads in AES-256-GCM
  - then JSON RPC: `DiscoverRequest` (reports a version; the extension treats that as "desktop
    app connected"), `GetBiometricsStatus`, `UnlockBiometrics` (returns the key),
    `AuthenticateBiometrics` (check only)
  - replies must use the `forwarded-bitwarden-ipc-message` envelope with `originalSource`,
    otherwise the extension records the source as `DesktopMain` and drops the frame
  - whether the extension actually uses this channel for unlocks depends on its remote
    `BiometricsSDKIPC` flag; when it is off, the older commands above are used
- The account's encryption key (the "biometric key" the extension wants) is read out of the
  unlocked browser extension and stored in the login keychain (this-device-only, readable while
  unlocked, never synced to iCloud)
- Same security model as the reference implementations: biometrics gate *access* to the stored
  key, they don't encrypt anything; other processes running as you can in principle reach the
  keychain (that is equally true with the official desktop client)

## Usage

1. **Keep `WardenBio.app` in a fixed location** (ideally `/Applications`). The manifest records
   the host's absolute path, so re-install it after moving the app.
2. Open the app (menu-bar fingerprint icon → "打开 WardenBio…") and click **安装** next to your
   browser on the **浏览器** (Browsers) tab. Chrome/Chromium/Edge/Brave/Vivaldi/Arc/Firefox are supported.
3. On the **密钥** (Key) tab click **复制提取脚本** (copy extraction script), paste it into the
   extension's background console (Chrome: `chrome://extensions` → Developer mode → Bitwarden →
   "service worker"; Firefox: `about:debugging` → "Inspect") and run it. It prints the User ID
   and the encryption key (`keyB64`).
4. Back on the **密钥** tab, paste both values → **保存并验证** (save & verify) → approve Touch ID.
5. In the Bitwarden extension, Settings → Account security → enable "Unlock with biometrics".
   After locking the extension, unlocking will now prompt for Touch ID.

## Uninstall

- App **浏览器** tab: click **卸载** for every configured browser (removes `com.8bit.bitwarden.json`)
- App **密钥** tab: delete each stored account key
- Quit the app and delete WardenBio.app

## Known limitations

- Safari is not supported (its extension model and native messaging differ)
- Browsers must be installed normally; if a browser cannot see the manifest under
  `~/Library/Application Support` (unusual sandboxed/portable setups), unlocking fails silently
- The host process is launched by the browser on demand once biometrics are enabled in the
  extension; the app itself does not need to be running (open it only to configure)
- The stored key is the vault's encryption key — never keep a plaintext copy anywhere
- Switching from a self-built copy (Apple Development signature) to a released build (Developer ID
  signature) can make the existing keychain entry unreadable; just enter the key again

## Build from source

Requirements: Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/build.sh            # Debug (default)
./scripts/build.sh Release    # Release
```

Output: `.build/derived/Build/Products/<config>/WardenBio.app` (with `BioHost` embedded in
`Contents/MacOS/`).

Unit tests (including crypto interoperability vectors from the Go reference implementation and a
handshake vector verified against snow):

```bash
xcodebuild -project WardenBio.xcodeproj -scheme WardenBio -derivedDataPath .build/derived test
```

## Releasing (maintainers)

```bash
./scripts/release.sh 0.1.0                    # bump → test → commit/push → archive → sign → notarize → package → tag → release
./scripts/release.sh 0.2.0 --prerelease beta  # pre-release
./scripts/release.sh 0.2.0 --dry-run          # bump + test + local commit only
./scripts/release.sh --package-only           # no git, no notarization — just produce dist/ artifacts
```

Pushing a tag runs the same packaging/notarization flow on GitHub Actions
(see `.github/workflows/release.yml`). One-time setup and details live in the "发布" (Releasing)
section of [AGENTS.md](./AGENTS.md).

## Repository layout

```
project.yml                   xcodegen project definition
Sources/Protocol/             protocol: framing, message models, AES-CBC/HMAC, SPKI/OAEP, Noise, CBOR
Sources/BioHost/              native messaging host (serve/store-key/list-keys/remove-key/test-unlock)
Sources/App/                  menu-bar app (SwiftUI: browsers / keys / settings / log)
Sources/Shared/               shared helpers (logging)
Tests/ProtocolTests/          protocol unit tests (Go interop vectors + handshake vector)
scripts/build.sh              xcodegen generate + xcodebuild one-shot build
scripts/release.sh            full local release flow
scripts/ci/                   packaging script used by CI
scripts/ExportOptions.plist   Developer ID export options
.github/workflows/release.yml tag-triggered cloud release
reference/                    reference implementations (bw-bio-handler, goldwarden; separate clones, not tracked)
```
