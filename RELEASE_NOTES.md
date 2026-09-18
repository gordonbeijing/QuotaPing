# QuotaPing 1.2.2

- 修复由于 URLSession 默认缓存导致的额度刷新展示问题，确保每次都能拉取到最新额度。
- 修复因 OpenAI 服务端变更导致的登录凭证（Token）主动刷新失败的问题（HTTP 400）。
