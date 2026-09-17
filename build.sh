#!/bin/bash
# 一键编译并打包 QuotaPing.app（单文件 swiftc + Sparkle 2）
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
SPARKLE_VERSION="2.10.0"
SPARKLE_DIR="$(pwd)/Vendor/Sparkle-${SPARKLE_VERSION}"

./scripts/prepare_sparkle.sh

echo "==> 编译 ($ARCH, 最低 macOS 14.0)…"
swiftc -O QuotaPing.swift \
  -framework AppKit -framework SwiftUI -framework Sparkle \
  -F "$SPARKLE_DIR" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -target "${ARCH}-apple-macosx14.0" \
  -o QuotaPing.bin

echo "==> 打包 .app…"
rm -rf QuotaPing.app
mkdir -p QuotaPing.app/Contents/MacOS
mkdir -p QuotaPing.app/Contents/Resources
mkdir -p QuotaPing.app/Contents/Frameworks
cp QuotaPing.bin QuotaPing.app/Contents/MacOS/QuotaPing
cp Info.plist QuotaPing.app/Contents/Info.plist
ditto "$SPARKLE_DIR/Sparkle.framework" QuotaPing.app/Contents/Frameworks/Sparkle.framework
ICON_INFO_PLIST="$(mktemp /tmp/quotaping-appicon-info.XXXXXX)"
xcrun actool Assets/AppIcon.xcassets \
  --compile QuotaPing.app/Contents/Resources \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_INFO_PLIST"
rm -f "$ICON_INFO_PLIST"
rm -f QuotaPing.bin

codesign --force --sign - QuotaPing.app
codesign --verify --deep --strict QuotaPing.app
echo "==> 完成：$(pwd)/QuotaPing.app"
echo "    运行：open $(pwd)/QuotaPing.app"
