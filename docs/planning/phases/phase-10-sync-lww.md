# phase-10 拉取 Manifest 与 LWW 合并

**What to build:** 新设备发现 Manifest；空则空库；LWW 合并；删除清 blob。

## 验收

- [ ] GET /v1/files 按 filename=library-manifest.json、created_at 降序、limit=1
- [ ] items 空 → 空曲库
- [ ] 实体 updatedAt LWW；pendingDelete 优先；Favorites 整表 LWW
- [ ] 同步 pendingDelete 时删除对应 server 文件
- [ ] 纯函数/LibrarySession 测试覆盖合并，不要求真 server
