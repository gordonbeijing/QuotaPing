#!/bin/bash
# 一键编译并打包 Universal 2 QuotaPing.app（Swift + Sparkle 2）
set -euo pipefail
cd "$(dirname "$0")"

SPARKLE_VERSION="2.10.0"
SPARKLE_DIR="$(pwd)/Vendor/Sparkle-${SPARKLE_VERSION}"
BUILD_DIR="$(mktemp -d /tmp/quotaping-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR/ModuleCache"

./scripts/prepare_sparkle.sh

echo "==> 编译 Universal 2 (arm64 + x86_64，最低 macOS 14.0)…"
for arch in arm64 x86_64; do
  swiftc -Osize QuotaPing.swift \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -framework AppKit -framework SwiftUI -framework Sparkle \
    -F "$SPARKLE_DIR" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -dead_strip \
    -target "${arch}-apple-macosx14.0" \
    -o "$BUILD_DIR/QuotaPing-${arch}"
done
lipo -create "$BUILD_DIR/QuotaPing-arm64" "$BUILD_DIR/QuotaPing-x86_64" \
  -output "$BUILD_DIR/QuotaPing"
strip -x "$BUILD_DIR/QuotaPing"

echo "==> 打包 .app…"
rm -rf QuotaPing.app
mkdir -p QuotaPing.app/Contents/MacOS
mkdir -p QuotaPing.app/Contents/Resources
mkdir -p QuotaPing.app/Contents/Frameworks
cp "$BUILD_DIR/QuotaPing" QuotaPing.app/Contents/MacOS/QuotaPing
cp Info.plist QuotaPing.app/Contents/Info.plist
chmod 644 QuotaPing.app/Contents/Info.plist
ditto "$SPARKLE_DIR/Sparkle.framework" QuotaPing.app/Contents/Frameworks/Sparkle.framework
ICON_INFO_PLIST="$(mktemp /tmp/quotaping-appicon-info.XXXXXX)"
mkdir -p "$BUILD_DIR/IconResources"
xcrun actool Assets/AppIcon.xcassets \
  --compile "$BUILD_DIR/IconResources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_INFO_PLIST"
cp "$BUILD_DIR/IconResources/AppIcon.icns" QuotaPing.app/Contents/Resources/AppIcon.icns
chmod 644 QuotaPing.app/Contents/Resources/AppIcon.icns
rm -f "$ICON_INFO_PLIST"
# Sparkle 内部 helper 已带正确的 ad-hoc 签名与 Hardened Runtime。
# 仅签名应用外层，不使用 --deep 改写嵌套组件。
codesign --force --sign - QuotaPing.app
codesign --verify --deep --strict QuotaPing.app
echo "==> 完成：$(pwd)/QuotaPing.app"
echo "    运行：open $(pwd)/QuotaPing.app"
