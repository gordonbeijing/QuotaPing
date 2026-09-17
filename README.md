# QuotaPing

macOS 菜单栏工具：**google.com 连通检测** + **ChatGPT 额度**（5 小时 / 每周两个维度）。
Swift/AppKit 实现，使用 Sparkle 2 提供应用内更新。

## 构建

```bash
bash build.sh
```

## 运行

```bash
open QuotaPing.app
```

双击运行，无 Dock 图标（LSUIElement）。菜单栏使用横向信息条：

- 左侧圆形符号表示 google.com 连通性：正常为勾、响应过慢为 `···`、仅连接超时显示叉，其他异常显示横线
- 5h 区域第一行显示下次重置时间（如 `15:30`），第二行显示剩余额度
- 1w 区域第一行显示下次重置日的英文星期缩写（如 `MON`），第二行显示剩余额度
- 5h 和 1w 的上下两行各自使用相同左边界对齐
- 整枚状态图标使用 macOS 菜单栏默认色，自动适配深浅外观

## 首次安装

对外分发请使用 `QuotaPing-<版本>-user-installer.zip`：

1. 完整解压 ZIP。
2. 双击“安装 QuotaPing.command”。
3. 脚本会安装到 `~/Applications`、清理下载隔离属性、校验签名并启动。

不要将免 Developer ID 签名的版本拖入系统级 `/Applications`；部分 macOS 26 环境会在启动前挂起 ad-hoc 签名应用。

## 使用

| 操作 | 效果 |
|---|---|
| 菜单栏 → 立即刷新 | 手动刷新连通性与额度 |
| 菜单栏的频率子菜单 | 设置连通检测频率、额度刷新频率 |
| 菜单栏 → 查看网络日志… | 在应用内查看最近 1000 条连接失败记录 |
| 菜单栏 → 检查更新… | 通过 Sparkle 检查、下载并安装新版本 |
| 菜单栏 → 帮助 | 重新打开功能说明（首次启动会自动显示） |
| 菜单栏 → 退出 ⌘Q | 退出 |

- 连通检测：对 `google.com/generate_204` 发起无缓存 GET，只接受来自原域名的 204；
  默认 30s，可设 5s～5min。RTT ≥ 500ms 的半连通状态按不可用显示红叉
- ChatGPT 额度：复用 Codex CLI 凭据（`~/.codex/auth.json`）调
  `chatgpt.com/backend-api/wham/usage`，默认 60s，可设 30s～15min
- 未登录 Codex 时额度区显示提示，连通检测不受影响；
  运行 `codex login` 后自动恢复（无需重启）

## 调试

```bash
QUOTAPING_DEBUG=1 ./QuotaPing.app/Contents/MacOS/QuotaPing
# 状态会输出到统一日志：log stream --predicate 'eventMessage CONTAINS QuotaPing'
```

连接超时、DNS 失败、HTTP 异常和慢速半连通会同时记录在应用内日志和 macOS 统一日志中。应用内日志保存在 `~/Library/Application Support/QuotaPing/network-failure-logs.json`，重启后仍保留，最多 1000 条。升级时会自动读取旧 GooglePing 日志。

## 发布更新

```bash
./scripts/package_release.sh
```

脚本会构建应用、生成 EdDSA 签名更新包、更新根目录的 `appcast.xml`，并在 `dist/` 生成面向首次安装的用户级安装包。然后提交并推送 `appcast.xml`，再将完整更新包、delta 和用户安装包上传到对应 GitHub Release。

Sparkle 2.10.0 二进制会在首次构建时从官方 Release 下载并校验 SHA-256；下载内容保存在已忽略的 `Vendor/` 目录。更新签名私钥保存在本机钥匙串，不应提交到仓库。
