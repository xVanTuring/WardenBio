#!/bin/bash
# 一键构建：xcodegen 生成工程并编译 WardenBio.app（内嵌 BioHost）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"

xcodegen generate

xcodebuild \
  -project WardenBio.xcodeproj \
  -scheme WardenBio \
  -configuration "$CONFIG" \
  -derivedDataPath .build/derived \
  build

APP=".build/derived/Build/Products/$CONFIG/WardenBio.app"
echo
echo "=== 构建完成 ==="
ls "$APP/Contents/MacOS/"
echo "App 路径: $PWD/$APP"
