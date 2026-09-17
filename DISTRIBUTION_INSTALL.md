# QuotaPing 安装说明

## 系统要求

- Apple Silicon Mac（M1/M2/M3/M4 等）
- macOS 14 或更高版本
- 如需查看 ChatGPT/Codex 额度，需先安装 Codex CLI 并执行 `codex login`

## 安装

1. 解压 `QuotaPing-1.1.0-macOS-arm64.zip`。
2. 将 `QuotaPing.app` 拖入“应用程序”文件夹。
3. 双击打开 QuotaPing。
4. 如 macOS 提示无法验证开发者，请打开“系统设置 → 隐私与安全性”。
5. 在页面底部找到 QuotaPing，点击“仍要打开”，再次确认“打开”。

成功打开一次后，之后可直接从“应用程序”或登录项启动。

## 安全校验

在终端进入压缩包所在目录，执行：

```bash
shasum -a 256 QuotaPing-1.1.0-macOS-arm64.zip
```

输出应与随包提供的 `.sha256` 文件一致。

> QuotaPing 未使用付费 Apple Developer ID 签名或 Apple 公证，因此首次启动需要用户手动确认。请仅从信任的分发渠道获取本应用。
