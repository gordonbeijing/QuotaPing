#!/bin/bash
# 构建 QuotaPing，签名更新包并生成 Sparkle appcast。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
TAG="v${VERSION}"
ARCHIVE_NAME="QuotaPing-${VERSION}-macOS-universal.zip"
INSTALLER_NAME="QuotaPing-${VERSION}-user-installer.zip"
UPDATES_DIR="$ROOT_DIR/updates"
ARCHIVE="$UPDATES_DIR/$ARCHIVE_NAME"
DIST_DIR="$ROOT_DIR/dist"
INSTALLER_ARCHIVE="$DIST_DIR/$INSTALLER_NAME"
STAGE_DIR="$(mktemp -d /tmp/quotaping-installer.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

bash ./build.sh
mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE"
rm -f "$UPDATES_DIR/QuotaPing${BUILD}-"*.delta
# macOS framework 依赖符号链接，使用 ditto 保留链接与权限。
ditto -c -k --keepParent QuotaPing.app "$ARCHIVE"
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
# generate_appcast 会将 URL prefix 同步到历史条目，恢复旧版本的真实 Release 地址。
/usr/bin/sed -E -i '' \
  -e 's|(releases/download/)v[^/]+/(QuotaPing-1\.1\.0-macOS-arm64\.zip)|\1v1.1.0/\2|' \
  -e 's|(releases/download/)v[^/]+/(QuotaPing-1\.2\.0-macOS-universal\.zip)|\1v1.2.0/\2|' \
  -e 's|(releases/download/)v[^/]+/(QuotaPing-1\.2\.1-macOS-universal\.zip)|\1v1.2.1/\2|' \
  -e 's|(releases/download/)v[^/]+/(QuotaPing-1\.2\.2-macOS-universal\.zip)|\1v1.2.2/\2|' \
  -e 's|(releases/download/)v[^/]+/(QuotaPing-1\.2\.3-macOS-universal\.zip)|\1v1.2.3/\2|' \
  "$UPDATES_DIR/appcast.xml"
cp "$UPDATES_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
rm -f "$UPDATES_DIR/appcast.xml"

# 首次安装包：应用 + 用户级安装脚本 + 说明。
PACKAGE_DIR="$STAGE_DIR/QuotaPing-${VERSION}"
mkdir -p "$PACKAGE_DIR" "$DIST_DIR"
ditto QuotaPing.app "$PACKAGE_DIR/QuotaPing.app"
cp installer/install.command "$PACKAGE_DIR/安装 QuotaPing.command"
cp DISTRIBUTION_INSTALL.md "$PACKAGE_DIR/安装说明.md"
chmod +x "$PACKAGE_DIR/安装 QuotaPing.command"
rm -f "$INSTALLER_ARCHIVE"
ditto -c -k --keepParent "$PACKAGE_DIR" "$INSTALLER_ARCHIVE"
(
  cd "$DIST_DIR"
  shasum -a 256 "$INSTALLER_NAME" > "$INSTALLER_NAME.sha256"
)

echo "==> 更新包：$ARCHIVE"
echo "==> 用户安装包：$INSTALLER_ARCHIVE"
echo "==> Appcast：$ROOT_DIR/appcast.xml"
echo "==> GitHub tag：$TAG"
