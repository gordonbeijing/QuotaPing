# QuotaPing 安装说明

## 系统要求

- Apple Silicon Mac（M1/M2/M3/M4 等）或 Intel Mac
- macOS 14 或更高版本
- 如需查看 ChatGPT/Codex 额度，需先安装 Codex CLI 并执行 `codex login`

## 安装

1. 解压 `QuotaPing-1.2.1-user-installer.zip`。
2. 打开解压后的 `QuotaPing-1.2.1` 文件夹。
3. 双击 **安装 QuotaPing.command**。
4. 如果 macOS 拦截脚本，右键点击它，选择“打开”；或在终端执行：

```bash
bash "/完整路径/安装 QuotaPing.command"
```

5. 脚本会安装到当前用户的 `~/Applications/QuotaPing.app`，并自动启动。

成功启动后 QuotaPing 仅显示在菜单栏，不会显示 Dock 图标或普通窗口。

## 安全校验

在终端进入压缩包所在目录，执行：

```bash
shasum -a 256 QuotaPing-1.2.1-user-installer.zip
```

输出应与随包提供的 `.sha256` 文件一致。

> QuotaPing 未使用付费 Apple Developer ID 签名或 Apple 公证，因此首次启动需要用户手动确认。请仅从信任的分发渠道获取本应用。
