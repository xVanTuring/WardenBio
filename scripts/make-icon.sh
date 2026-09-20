#!/usr/bin/env bash
#
# 把 Sources/App/Resources/AppIcon.svg 光栅化成 macOS 的 AppIcon.appiconset
# （去重布局：7 个 PNG，在 Contents.json 里复用到 10 个 idiom/scale 槽位）。
#
# 改过 AppIcon.svg 之后跑一次。生成的 PNG 和 Contents.json 都入库，
# 所以打包链路（scripts/release.sh、CI）不需要装 rsvg-convert，只有这个脚本需要。
#
# 依赖：rsvg-convert —— 没有的话自己装：brew install librsvg
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Sources/App/Resources/AppIcon.svg"
ASSETS="Sources/App/Resources/Assets.xcassets"
DEST="$ASSETS/AppIcon.appiconset"

[[ -f "$SRC" ]] || { echo "ERROR: 找不到 $SRC" >&2; exit 1; }
command -v rsvg-convert >/dev/null \
    || { echo "ERROR: PATH 里没有 rsvg-convert，装一下：brew install librsvg" >&2; exit 1; }

mkdir -p "$DEST"

# 一个像素尺寸一个文件，Contents.json 里一个文件挂多个槽位
# （比如 icon_32.png 同时是 16x16@2x 和 32x32@1x）。
sizes=(16 32 64 128 256 512 1024)

echo "==> 光栅化 $SRC"
for px in "${sizes[@]}"; do
    name="icon_${px}.png"
    printf "  %s  (%d×%d)\n" "$name" "$px" "$px"
    rsvg-convert -w "$px" -h "$px" "$SRC" -o "$DEST/$name"
done

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# 资产目录根目录也要有自己的 Contents.json，否则 Xcode 不认这个 bundle。
if [[ ! -f "$ASSETS/Contents.json" ]]; then
    cat > "$ASSETS/Contents.json" <<'JSON'
{ "info" : { "version" : 1, "author" : "xcode" } }
JSON
fi

echo "==> 已写入 $DEST + Contents.json"
