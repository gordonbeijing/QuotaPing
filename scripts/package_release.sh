#!/bin/bash
# 构建 QuotaPing，签名更新包并生成 Sparkle appcast。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
ARCH="$(uname -m)"
TAG="v${VERSION}"
ARCHIVE_NAME="QuotaPing-${VERSION}-macOS-${ARCH}.zip"
UPDATES_DIR="$ROOT_DIR/updates"
ARCHIVE="$UPDATES_DIR/$ARCHIVE_NAME"

bash ./build.sh
mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent QuotaPing.app "$ARCHIVE"
cp RELEASE_NOTES.md "$UPDATES_DIR/${ARCHIVE_NAME%.zip}.md"

Vendor/Sparkle-2.10.0/bin/generate_appcast \
  --download-url-prefix "https://github.com/gordonbeijing/QuotaPing/releases/download/${TAG}/" \
  --link "https://github.com/gordonbeijing/QuotaPing" \
  --embed-release-notes \
  --versions "$BUILD" \
  -o "$ROOT_DIR/appcast.xml" \
  "$UPDATES_DIR"

echo "==> 更新包：$ARCHIVE"
echo "==> Appcast：$ROOT_DIR/appcast.xml"
echo "==> GitHub tag：$TAG"
