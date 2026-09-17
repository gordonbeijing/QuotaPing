#!/bin/bash
# 下载并校验 Sparkle 官方二进制发行包。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_VERSION="2.10.0"
EXPECTED_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST_DIR="$ROOT_DIR/Vendor/Sparkle-${SPARKLE_VERSION}"

if [[ -f "$DEST_DIR/Sparkle.framework/Sparkle" ]]; then
  exit 0
fi

TEMP_DIR="$(mktemp -d /tmp/quotaping-sparkle.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ARCHIVE="$TEMP_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "==> 下载 Sparkle ${SPARKLE_VERSION}…"
if command -v gh >/dev/null 2>&1; then
  gh release download "$SPARKLE_VERSION" \
    --repo sparkle-project/Sparkle \
    --pattern "Sparkle-${SPARKLE_VERSION}.tar.xz" \
    --dir "$TEMP_DIR"
else
  curl -fL \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -o "$ARCHIVE"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Sparkle 校验失败：期望 $EXPECTED_SHA256，实际 $ACTUAL_SHA256" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
tar -xJf "$ARCHIVE" -C "$DEST_DIR"
echo "==> Sparkle ${SPARKLE_VERSION} 已准备"
