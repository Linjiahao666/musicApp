# phase-06 标签、Cover、Lyrics、文件夹导入与去重

**What to build:** ID3/Vorbis、Cover 512px、`.lrc` 优先、占位、歌词显示、文件夹扫描、Windows 拖拽、内容哈希去重。

## 验收

- [ ] 标签填标题/主歌手/Album/Album Artist/曲序；缺标签用文件名
- [ ] Cover 最长边 512 JPEG；缺失占位
- [ ] `.lrc` 优先于内嵌 Lyrics；播放页有则显示
- [ ] 文件夹递归扫描；Windows 可拖拽
- [ ] 同内容哈希跳过并提示
