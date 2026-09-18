# QuotaPing 1.2.8

- 额度查询迁移到官方 `codex app-server`，QuotaPing 不再直接读取、修改或刷新登录凭据。
- 根据官方返回的窗口时长识别 5 小时与每周额度，兼容不同套餐和响应顺序。
- 增加 Codex 可执行文件发现、JSON-RPC 超时及登录错误提示。
