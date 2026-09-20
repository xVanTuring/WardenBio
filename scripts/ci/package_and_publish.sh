#!/usr/bin/env bash
# scripts/ci/package_and_publish.sh
#
# scripts/release.sh 后半段的 CI 版本。跑在 GitHub Actions 的 macOS runner 上，
# 前置步骤由 .github/workflows/release.yml 完成：
#   - 把 Developer ID Application 证书导进临时 keychain
#   - 装好 xcodegen 并生成 WardenBio.xcodeproj
#
# 这里做的事：归档（Developer ID 手动签名）→ 导出 → 公证（Apple ID + App 专用密码）
# → staple → 打 dmg → 公证 → staple → 校验和 → 建 GitHub Release。
# **不改版本**（版本号已经在被打 tag 的那个提交里）、**不打 tag**（tag 推送才是触发源）。
#
# 需要的环境变量：
#   TAG                 例如 v0.1.0（或 v0.1.0-beta）
#   APPLE_ID            Apple 账号邮箱（公证用）
#   APPLE_APP_PASSWORD  App 专用密码（appleid.apple.com）
#   APPLE_TEAM_ID       T8F5T6HKG8
#   GH_TOKEN            gh CLI 的令牌，workflow 传 github.token
# 可选：
#   NOTES_FILE          发布说明文件；不给则用 release-notes/$TAG.md，再没有就自动生成
#
# 一次性的 secret 配置见 AGENTS.md 的「发布」一节。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ── 常量（跟 scripts/release.sh 对齐）───────────────────────────────
SCHEME="WardenBio"
PROJECT="WardenBio.xcodeproj"
PRODUCT="WardenBio"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
BUILD_DIR=".build/release"

: "${TAG:?需要 TAG（例如 v0.1.0）}"
: "${APPLE_ID:?需要 APPLE_ID}"
: "${APPLE_APP_PASSWORD:?需要 APPLE_APP_PASSWORD}"
: "${APPLE_TEAM_ID:?需要 APPLE_TEAM_ID}"

# tag 形如 v0.1.0 或 v0.1.0-beta，拆成版本号和渠道后缀
RAW="${TAG#v}"
VERSION="${RAW%%-*}"
if [[ "$RAW" == *-* ]]; then
    PRERELEASE="${RAW#*-}"
    TITLE="v${VERSION} ${PRERELEASE}"
    ZIP_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.dmg"
    PRERELEASE_FLAG="--prerelease"
else
    PRERELEASE=""
    TITLE="v${VERSION}"
    ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
    PRERELEASE_FLAG=""
fi

GH_REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"

DIST_DIR="dist/${TAG}"
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"
ARCHIVE="${BUILD_DIR}/${PRODUCT}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"

echo "==> 打包 ${TAG}（版本 ${VERSION}${PRERELEASE:+，渠道 $PRERELEASE}）"
rm -rf "$DIST_DIR" "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$DIST_DIR"

notary() {
    # CI 上没有 keychain profile，公证走 Apple ID + App 专用密码
    xcrun notarytool "$@" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID"
}

# ── 发布门禁：单元测试 ──────────────────────────────────────────────
echo "==> 跑单元测试"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -derivedDataPath "$BUILD_DIR" -quiet test 2>&1 | tail -20

# ── 归档（Developer ID 手动签名）────────────────────────────────────
# runner 上只导入了 Developer ID Application 证书，没有 Apple Development
# 证书，所以不能用 project.yml 里的默认签名设置，必须在命令行覆盖。
echo "==> 归档 Release（Developer ID 手动签名）"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    -quiet

[[ -d "$ARCHIVE" ]] || { echo "ERROR: 没有产出归档 $ARCHIVE" >&2; exit 1; }

# 缺 ApplicationProperties 的话导出必然失败，早点报错好定位
# （靠 project.yml 里 BioHost 的 SKIP_INSTALL: YES 保证）
/usr/libexec/PlistBuddy -c "Print :ApplicationProperties" "$ARCHIVE/Info.plist" >/dev/null 2>&1 \
    || { echo "ERROR: 归档缺少 ApplicationProperties，检查 BioHost 的 SKIP_INSTALL。" >&2; exit 1; }

# ── 导出 + Developer ID 重签 ────────────────────────────────────────
echo "==> 导出 Developer ID 版本（用 ${EXPORT_OPTIONS}）"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -20

BUILT_APP="${EXPORT_DIR}/${PRODUCT}.app"
[[ -d "$BUILT_APP" ]] || { echo "ERROR: 导出的 .app 不存在：$BUILT_APP" >&2; exit 1; }
ditto "$BUILT_APP" "$APP"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Format" || true

# ── zip + 公证 .app ─────────────────────────────────────────────────
echo "==> 打 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> 提交 .zip 给 Apple 公证（--wait）"
notary submit "$ZIP" --wait 2>&1 | tee "${DIST_DIR}/notary-app.log"

echo "==> staple .app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true

# 公证前那份 zip 不带票据，必须用 staple 过的 .app 重新打
echo "==> 用带票据的 .app 重新打 zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── dmg ─────────────────────────────────────────────────────────────
echo "==> 打 dmg"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${PRODUCT} ${VERSION}" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> 公证 + staple .dmg"
notary submit "$DMG" --wait 2>&1 | tee "${DIST_DIR}/notary-dmg.log"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── 校验和 ──────────────────────────────────────────────────────────
echo "==> 生成 SHA256SUMS.txt"
( cd "$DIST_DIR" && shasum -a 256 "$ZIP_ASSET" "$DMG_ASSET" > SHA256SUMS.txt && cat SHA256SUMS.txt )

# ── GitHub Release ──────────────────────────────────────────────────
NOTES_FILE="${NOTES_FILE:-release-notes/${TAG}.md}"
echo "==> 建 GitHub Release ${TAG}"
if [[ -f "$NOTES_FILE" ]]; then
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" \
        --notes-file "$NOTES_FILE" \
        "$ZIP" "$DMG" "${DIST_DIR}/SHA256SUMS.txt"
else
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" \
        --generate-notes \
        "$ZIP" "$DMG" "${DIST_DIR}/SHA256SUMS.txt"
fi

echo
echo "================================================================"
echo "发布 ${TAG} 完成"
echo "  .zip : ${ZIP}"
echo "  .dmg : ${DMG}"
echo "  URL  : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "================================================================"
