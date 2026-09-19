# phase-11 云端 Range 播放、缓存 LRU 与固定下载

**What to build:** 播放源本机 > 缓存 > Range；2GB LRU；固定下载；需联网标记。

## 验收

- [ ] 无本机文件时用 file-access JWT Range 播放
- [ ] 边播边写入缓存；默认 2GB LRU 可配置
- [ ] isPinnedDownload 不参与淘汰
- [ ] 仅云端且无缓存时标记需联网
