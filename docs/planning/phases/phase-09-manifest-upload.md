# phase-09 dirty 资源与 Manifest 上传

**What to build:** 有网时后台上传 dirty 音频/Cover/sidecar 与 Manifest。

## 验收

- [ ] ≤10MB 直传，更大分片；filename 按规格
- [ ] 上传完整 Manifest JSON（含 Favorites）
- [ ] 成功后更新 manifestFileId 并删除上一份
- [ ] FakeStoreFiles 测试覆盖直传/分片选择与 Manifest 形状
