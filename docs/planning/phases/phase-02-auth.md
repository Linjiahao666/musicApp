# phase-02 注册登录与会话保持

**What to build:** 用户能注册、登录、自动刷新 Access、登出；凭证留在本机。

## 验收

- [x] LibrarySession 暴露注册/登录/登出；StoreFiles 实现对应 HTTP
- [x] Access 过期走 refresh；失败则需重新登录
- [x] 假端口测试覆盖成功登录与刷新
- [x] 简单登录/注册界面，文案中文
