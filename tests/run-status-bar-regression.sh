#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/quotaping-regression.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/QuotaPing.app/Contents/MacOS"
cp Info.plist "$TEST_DIR/QuotaPing.app/Contents/Info.plist"
sed '/^let app = NSApplication.shared$/,$d' QuotaPing.swift > "$TEST_DIR/main.swift"
cat tests/StatusBarRegression.swift >> "$TEST_DIR/main.swift"
swiftc "$TEST_DIR/main.swift" \
  -module-cache-path "$TEST_DIR/ModuleCache" \
  -F Vendor/Sparkle-2.10.0 \
  -Xlinker -rpath -Xlinker "$(pwd)/Vendor/Sparkle-2.10.0" \
  -o "$TEST_DIR/QuotaPing.app/Contents/MacOS/QuotaPing"
"$TEST_DIR/QuotaPing.app/Contents/MacOS/QuotaPing" > "$TEST_DIR/result.txt"
cat "$TEST_DIR/result.txt"
grep -q "PASS: startup quota rendering and live menu updates" "$TEST_DIR/result.txt"
