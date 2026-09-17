#!/bin/bash
# 构建 QuotaPing，签名更新包并生成 Sparkle appcast。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
TAG="v${VERSION}"
ARCHIVE_NAME="QuotaPing-${VERSION}-macOS-universal.zip"
UPDATES_DIR="$ROOT_DIR/updates"
ARCHIVE="$UPDATES_DIR/$ARCHIVE_NAME"

bash ./build.sh
mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE"
rm -f "$UPDATES_DIR/QuotaPing${BUILD}-"*.delta
COPYFILE_DISABLE=1 /usr/bin/zip -qry -9 "$ARCHIVE" QuotaPing.app
cp RELEASE_NOTES.md "$UPDATES_DIR/${ARCHIVE_NAME%.zip}.md"
# 让 Sparkle 复用既有 feed，从而保留历史版本各自的 Release URL。
cp "$ROOT_DIR/appcast.xml" "$UPDATES_DIR/appcast.xml"

Vendor/Sparkle-2.10.0/bin/generate_appcast \
  --download-url-prefix "https://github.com/gordonbeijing/QuotaPing/releases/download/${TAG}/" \
  --link "https://github.com/gordonbeijing/QuotaPing" \
  --embed-release-notes \
  --versions "$BUILD" \
  -o "$UPDATES_DIR/appcast.xml" \
  "$UPDATES_DIR"
# generate_appcast 会将 URL prefix 同步到历史条目，恢复 1.1.0 的真实 Release 地址。
/usr/bin/sed -E -i '' \
  's|(releases/download/)v[^/]+/(QuotaPing-1\.1\.0-macOS-arm64\.zip)|\1v1.1.0/\2|' \
  "$UPDATES_DIR/appcast.xml"
cp "$UPDATES_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
rm -f "$UPDATES_DIR/appcast.xml"

echo "==> 更新包：$ARCHIVE"
echo "==> Appcast：$ROOT_DIR/appcast.xml"
echo "==> GitHub tag：$TAG"
