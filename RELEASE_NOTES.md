# QuotaPing 1.2.1

- 新增用户级安装脚本，默认安装到 `~/Applications`，避免系统级目录对 ad-hoc 应用的额外拦截。
- 安装时自动清理下载隔离属性、校验签名、备份旧版本并启动应用。
- 修正 Sparkle.framework 归档方式，完整保留符号链接和嵌套 helper 签名。
