#!/usr/bin/env bash
# scripts/release.sh
#
# 改版本 → 跑测试 → 提交推送 → 归档 → Developer ID 重签 → 公证 → staple →
# zip + dmg → 校验和 → 打 tag → 建 GitHub Release。
#
# 用法：
#   ./scripts/release.sh <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]
#   ./scripts/release.sh --package-only
#
# 示例：
#   ./scripts/release.sh 0.1.0
#   ./scripts/release.sh 0.2.0 --prerelease beta
#   ./scripts/release.sh 0.2.0 --notes-file release-notes/v0.2.0.md
#   ./scripts/release.sh 0.2.0 --dry-run       # 只改版本 + 跑测试 + 本地提交
#   ./scripts/release.sh --package-only        # 不碰 git、不公证，只产出本地包
#
# 发布说明可以写双语：用 "<!-- lang:en -->" / "<!-- lang:zh -->" 分段。
# 在 GitHub 上这两行是 HTML 注释、不可见，正文就是双语堆叠；单语就直接写。
# 模板见 release-notes/TEMPLATE.md。
#
# 一次性的本机准备（Developer ID 证书、notarytool 凭据）见 AGENTS.md 的「发布」一节。

set -euo pipefail

# 脚本自己定位仓库根目录：从 IDE 任务里跑也不会错路径
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── 项目常量 ────────────────────────────────────────────────────────
TEAM_ID="T8F5T6HKG8"
# 公证凭据存在 keychain 里的 profile 名；没有就按 AGENTS.md 建一个，
# 或者用 NOTARY_PROFILE=noticky-notary 复用同一 Apple 账号下的旧 profile。
NOTARY_PROFILE="${NOTARY_PROFILE:-wardenbio-notary}"
SCHEME="WardenBio"
PROJECT="WardenBio.xcodeproj"
PRODUCT="WardenBio"
INFO_PLIST="Sources/App/Info.plist"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
BUILD_DIR=".build/release"

# ── 参数 ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
用法: $(basename "$0") <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]
      $(basename "$0") --package-only

  <version>          CFBundleShortVersionString，例如 0.1.0
  --prerelease X     预发布：tag 变成 v<version>-<X>，GitHub Release 标 pre-release
  --notes-file PATH  作为 GitHub Release 正文；不给则用 release-notes/v<tag>.md，
                     再没有就按上一个 tag 之后的提交自动生成
  --dry-run          只改版本 + 跑测试 + 本地提交，不推送、不归档、不发版
  --package-only     完全跳过 git / 公证 / 发版，只构建并产出 dist/ 下的包
EOF
    exit 1
}

VERSION=""
PRERELEASE=""
NOTES_FILE=""
DRY_RUN=false
PACKAGE_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerelease)   PRERELEASE="${2:?--prerelease 需要值}"; shift 2 ;;
        --notes-file)   NOTES_FILE="${2:?--notes-file 需要路径}"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --package-only) PACKAGE_ONLY=true; shift ;;
        -h|--help)      usage ;;
        -*)             echo "未知参数: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
            else echo "多余的位置参数: $1" >&2; usage; fi
            ;;
    esac
done

if [[ "$PACKAGE_ONLY" == "true" ]]; then
    [[ -z "$VERSION" ]] || { echo "ERROR: --package-only 不接受版本号（它不改版本）。" >&2; usage; }
    # 不改版本、不打 tag，dist 目录按当前版本号命名，跟真 tag 区分开
    VERSION="$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    TAG="v${VERSION}-local"
    TITLE="local build"
    PRERELEASE_FLAG=""
else
    [[ -z "$VERSION" ]] && usage
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || { echo "ERROR: 版本号必须是 X.Y.Z（收到 '$VERSION'）" >&2; exit 1; }
    if [[ -n "$PRERELEASE" ]]; then
        TAG="v${VERSION}-${PRERELEASE}"
        TITLE="v${VERSION} ${PRERELEASE}"
        PRERELEASE_FLAG="--prerelease"
    else
        TAG="v${VERSION}"
        TITLE="v${VERSION}"
        PRERELEASE_FLAG=""
    fi
fi

if [[ -n "$PRERELEASE" ]]; then
    ZIP_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.dmg"
else
    ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
fi
DIST_DIR="dist/${TAG}"
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"
ARCHIVE="${BUILD_DIR}/${PRODUCT}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"

echo "==> 版本 $VERSION  •  tag $TAG  •  产物 $ZIP_ASSET + $DMG_ASSET"

# ── 预检 ────────────────────────────────────────────────────────────
echo "==> 预检"

[[ -f project.yml ]] || { echo "ERROR: 请在仓库根目录运行（这里没有 project.yml）" >&2; exit 1; }
[[ -f "$EXPORT_OPTIONS" ]] || { echo "ERROR: 缺少 $EXPORT_OPTIONS" >&2; exit 1; }

command -v xcodegen >/dev/null \
    || { echo "ERROR: 找不到 xcodegen（brew install xcodegen）" >&2; exit 1; }

security find-identity -v -p codesigning \
    | grep -q "Developer ID Application.*${TEAM_ID}" \
    || { echo "ERROR: keychain 里没有 team ${TEAM_ID} 的 Developer ID Application 证书。" >&2
         echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application。" >&2
         exit 1; }

# WardenBio 没有 entitlements，所以不需要 Developer ID provisioning profile，
# 这里也就没有 Perch 那样的 profile 检查。将来加了 App Group / iCloud 之类的
# entitlement，就得补上 profile 以及 ExportOptions.plist 里的 provisioningProfiles 段。

if [[ "$PACKAGE_ONLY" != "true" ]]; then
    command -v gh >/dev/null \
        || { echo "ERROR: 找不到 gh CLI（brew install gh）" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 \
        || { echo "ERROR: gh 未登录，先跑 gh auth login" >&2; exit 1; }

    GH_REPO="${GH_REPO:-$(git remote get-url origin 2>/dev/null \
        | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
    [[ -n "$GH_REPO" ]] || { echo "ERROR: 没有 origin 远端，先 git remote add origin …" >&2; exit 1; }

    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || { echo "ERROR: notarytool 凭据 '$NOTARY_PROFILE' 不存在或已失效。" >&2
             echo "       建一次：xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
             echo "                 --apple-id <Apple ID> --team-id $TEAM_ID --password <App 专用密码>" >&2
             echo "       同一 Apple 账号已有 profile 时也可以直接复用：" >&2
             echo "                 NOTARY_PROFILE=<已有的 profile 名> $0 …" >&2
             exit 1; }

    [[ -z "$(git status --porcelain)" ]] \
        || { echo "ERROR: 工作区不干净，先提交或 stash。" >&2
             git status --short >&2; exit 1; }

    if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        echo "ERROR: 本地已存在 tag ${TAG}" >&2; exit 1
    fi
    if git ls-remote --tags origin "${TAG}" 2>/dev/null | grep -q "refs/tags/${TAG}$"; then
        echo "ERROR: 远端已存在 tag ${TAG}" >&2; exit 1
    fi

    if [[ -z "$NOTES_FILE" && -f "release-notes/${TAG}.md" ]]; then
        NOTES_FILE="release-notes/${TAG}.md"
        echo "    发布说明: $NOTES_FILE"
    fi
    if [[ -n "$NOTES_FILE" ]]; then
        [[ -f "$NOTES_FILE" ]] || { echo "ERROR: 找不到 --notes-file：$NOTES_FILE" >&2; exit 1; }
    fi
fi

# .xcodeproj 是 gitignore 的产物，新 clone 里没有；这里先补出来。
# 此时 project.yml 还没改，生成出来的 Info.plist 不会产生 diff。
if [[ ! -d "$PROJECT" ]]; then
    echo "==> 首次生成 ${PROJECT}"
    xcodegen >/dev/null
fi

# ── 改版本 ──────────────────────────────────────────────────────────
if [[ "$PACKAGE_ONLY" != "true" ]]; then
    current_short=$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    current_build=$(grep -E 'CFBundleVersion:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
    next_build=$((current_build + 1))

    echo "==> 版本 ${current_short}（build ${current_build}）→ ${VERSION}（build ${next_build}）"
    # macOS 的 BSD sed 必须给 -i 一个备份后缀，用完删掉
    sed -i.bak -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
    sed -i.bak -E "s/(CFBundleVersion: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
    rm -f project.yml.bak

    xcodegen >/dev/null
fi

# ── 发布门禁：单元测试 ──────────────────────────────────────────────
# 协议帧和密码学都在 ProtocolTests 里，测试不过就别发。
echo "==> 跑单元测试"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -derivedDataPath "$BUILD_DIR" -quiet test 2>&1 | tail -20; then
    echo "ERROR: 测试未通过，发布中止。" >&2
    if [[ "$PACKAGE_ONLY" != "true" ]]; then
        echo "       回滚版本号：git checkout -- project.yml $INFO_PLIST && xcodegen" >&2
    fi
    exit 1
fi

# ── 提交版本变更 ────────────────────────────────────────────────────
if [[ "$PACKAGE_ONLY" != "true" ]]; then
    echo "==> 提交版本变更"
    git add project.yml "$INFO_PLIST"
    git commit -m "release: bump to ${VERSION} (build ${next_build})"

    # 兜底：pre-commit hook 若改了别的东西，别把错的树推上去
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "ERROR: 版本提交后工作区仍不干净，先处理再推送。" >&2
        git status --short >&2
        exit 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "==> [dry-run] 到此为止，不推送、不打包。"
        echo "    撤销：git reset --hard HEAD~1"
        exit 0
    fi

    echo "==> 推送 main"
    git push origin main
fi

# ── 清理产物目录 ────────────────────────────────────────────────────
echo "==> 清理 ${DIST_DIR}"
rm -rf "$DIST_DIR" "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$DIST_DIR"

# ── 归档（Apple Development 自动签名）────────────────────────────────
echo "==> 归档 Release（可能要一两分钟）"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -quiet \
    archive

[[ -d "$ARCHIVE" ]] || { echo "ERROR: 没有产出归档 $ARCHIVE" >&2; exit 1; }

# 归档里必须有 ApplicationProperties，否则 -exportArchive 会报
# 'exportOptionsPlist error for key "method" expected one {}'。
# 内嵌的 BioHost 靠 project.yml 里的 SKIP_INSTALL: YES 不进归档产物，别去掉那条。
/usr/libexec/PlistBuddy -c "Print :ApplicationProperties" "$ARCHIVE/Info.plist" >/dev/null 2>&1 \
    || { echo "ERROR: 归档缺少 ApplicationProperties，导出一定会失败。" >&2
         echo "       检查 project.yml 里 BioHost 的 SKIP_INSTALL: YES 还在不在。" >&2
         exit 1; }

# ── 导出 + Developer ID 重签 ────────────────────────────────────────
echo "==> 导出并重签为 Developer ID（用 ${EXPORT_OPTIONS}）"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    | tail -20

BUILT_APP="${EXPORT_DIR}/${PRODUCT}.app"
[[ -d "$BUILT_APP" ]] || { echo "ERROR: 导出的 .app 不存在：$BUILT_APP" >&2; exit 1; }

echo "==> 拷进 ${DIST_DIR}/"
ditto "$BUILT_APP" "$APP"

echo "==> 校验签名"
# --deep 会一并校验内嵌的 BioHost；--strict 抓资源哈希对不上的情况
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Format" || true
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/BioHost"

# 公证前 spctl 必然报错（票据还没 staple），这里只是留个记录
echo "==> 公证前的 Gatekeeper 评估（此时报错是正常的）："
spctl --assess --verbose=4 --type execute "$APP" 2>&1 || true

# ── zip + 公证 .app ─────────────────────────────────────────────────
echo "==> 打 zip"
# --sequesterRsrc 是 Apple 要求的：否则 Finder 解压会在 bundle 里留下 ._ 文件，
# 破坏签名封条，用户手动解压后会被 Gatekeeper 拒绝。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$PACKAGE_ONLY" != "true" ]]; then
    echo "==> 提交 .zip 给 Apple 公证（--wait 会等到出结果）"
    NOTARY_LOG_ZIP="${DIST_DIR}/notary-app.log"
    if ! xcrun notarytool submit "$ZIP" \
           --keychain-profile "$NOTARY_PROFILE" \
           --wait 2>&1 | tee "$NOTARY_LOG_ZIP"; then
        echo "ERROR: .app 公证失败，日志见 $NOTARY_LOG_ZIP" >&2
        echo "       取详细日志：xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi

    echo "==> 把公证票据 staple 到 .app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    echo "==> staple 后的 Gatekeeper 评估："
    spctl -a -t exec -vv "$APP" 2>&1 || true

    # 重新打 zip：公证前那份不带票据，分发出去 Gatekeeper 仍会拦
    echo "==> 用带票据的 .app 重新打 zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

# ── dmg ─────────────────────────────────────────────────────────────
echo "==> 打 dmg"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create \
    -volname "${PRODUCT} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

if [[ "$PACKAGE_ONLY" != "true" ]]; then
    echo "==> 提交 .dmg 给 Apple 公证"
    NOTARY_LOG_DMG="${DIST_DIR}/notary-dmg.log"
    if ! xcrun notarytool submit "$DMG" \
           --keychain-profile "$NOTARY_PROFILE" \
           --wait 2>&1 | tee "$NOTARY_LOG_DMG"; then
        echo "ERROR: .dmg 公证失败，日志见 $NOTARY_LOG_DMG" >&2
        exit 1
    fi

    echo "==> staple .dmg"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

# ── 校验和 ──────────────────────────────────────────────────────────
echo "==> 生成 SHA256SUMS.txt"
( cd "$DIST_DIR" && shasum -a 256 "$ZIP_ASSET" "$DMG_ASSET" > SHA256SUMS.txt && cat SHA256SUMS.txt )

# ── package-only 到此为止 ───────────────────────────────────────────
if [[ "$PACKAGE_ONLY" == "true" ]]; then
    echo
    echo "================================================================"
    echo "本地打包完成（未公证、未发版）"
    echo "  .app : ${APP}"
    echo "  .zip : ${ZIP}（$(du -h "$ZIP" | cut -f1)）"
    echo "  .dmg : ${DMG}（$(du -h "$DMG" | cut -f1)）"
    echo "================================================================"
    exit 0
fi

# ── tag + GitHub Release ────────────────────────────────────────────
echo "==> 打 tag ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> 建 GitHub Release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" $PRERELEASE_FLAG \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE" \
        "$ZIP" "$DMG" "${DIST_DIR}/SHA256SUMS.txt"
else
    # 没给说明文件就按上一个 tag 之后的提交自动生成
    gh release create "$TAG" $PRERELEASE_FLAG \
        --title "$TITLE" \
        --generate-notes \
        "$ZIP" "$DMG" "${DIST_DIR}/SHA256SUMS.txt"
fi

echo
echo "================================================================"
echo "发布 ${TAG} 完成"
echo "  .app : ${APP}"
echo "  .zip : ${ZIP}（$(du -h "$ZIP" | cut -f1)）"
echo "  .dmg : ${DMG}（$(du -h "$DMG" | cut -f1)）"
echo "  URL  : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "================================================================"
echo
echo "发公告前的冒烟测试："
echo "  1. open ${DMG} → 把 ${PRODUCT}.app 拖进 /Applications（manifest 记的是绝对路径，别放别处）"
echo "  2. 启动 app → 「浏览器」页给浏览器点「安装」；若之前配过别的路径，先「卸载」再装"
echo "  3. 「密钥」页点「复制提取脚本」→ 扩展后台控制台运行 → 录入 User ID 与密钥"
echo "  4. 扩展解锁一次，确认 Touch ID 能弹出并解锁"
echo "  5. 若旧版本的密钥读不出来（签名主体变了），重新录入即可"
