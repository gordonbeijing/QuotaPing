#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/QuotaPing.app"
TARGET_ROOT="$HOME/Applications"
TARGET_APP="$TARGET_ROOT/QuotaPing.app"
BACKUP_ROOT="$HOME/Library/Application Support/QuotaPing/Install Backups"
BACKUP_APP=""

pause_if_interactive() {
  if [[ -t 0 ]]; then
    printf '\n按回车键关闭此窗口…'
    read -r _
  fi
}

fail() {
  printf '\n安装失败：%s\n' "$1" >&2
  pause_if_interactive
  exit 1
}

[[ -d "$SOURCE_APP" ]] || fail "安装包中缺少 QuotaPing.app，请完整解压后再运行。"
[[ "$TARGET_APP" == "$HOME/Applications/QuotaPing.app" ]] || fail "安装目标路径异常。"

printf 'QuotaPing 用户级安装程序\n'
printf '安装位置：%s\n\n' "$TARGET_APP"

pkill -x QuotaPing 2>/dev/null || true
mkdir -p "$TARGET_ROOT" "$BACKUP_ROOT"

if [[ -e "$TARGET_APP" ]]; then
  BACKUP_APP="$BACKUP_ROOT/QuotaPing-$(date '+%Y%m%d-%H%M%S')-$$.app"
  mv "$TARGET_APP" "$BACKUP_APP"
  printf '已备份旧版本：%s\n' "$BACKUP_APP"
fi

if ! ditto "$SOURCE_APP" "$TARGET_APP"; then
  [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$TARGET_APP"
  fail "复制应用失败。"
fi

# 浏览器下载会添加隔离属性；用户主动运行本脚本即授权安装此应用。
xattr -cr "$TARGET_APP" || true

if ! codesign --verify --deep --strict "$TARGET_APP"; then
  mv "$TARGET_APP" "$BACKUP_ROOT/QuotaPing-invalid-$(date '+%Y%m%d-%H%M%S')-$$.app"
  [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$TARGET_APP"
  fail "代码签名校验失败，已恢复旧版本。"
fi

open -n "$TARGET_APP"

for _ in {1..20}; do
  if pgrep -f "$TARGET_APP/Contents/MacOS/QuotaPing" >/dev/null; then
    printf '\n安装完成，QuotaPing 已在菜单栏运行。\n'
    if [[ -e /Applications/QuotaPing.app ]]; then
      printf '提示：系统“应用程序”中仍有旧副本，建议移除 /Applications/QuotaPing.app。\n'
    fi
    pause_if_interactive
    exit 0
  fi
  sleep 0.25
done

fail "应用未能启动。请确认系统版本为 macOS 14 或更高版本。"
