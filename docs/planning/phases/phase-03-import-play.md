# phase-03 导入一首音频后能在歌曲列表点播

**What to build:** 选单个文件 → 拷进应用目录 → 歌曲列表出现 Song → 点播本机文件。

## 验收

- [x] 导入拷贝到应用目录，Song 出现在列表
- [x] 点播走 localAudioPath；播放暂停拖进度
- [x] 不依赖登录
- [x] FakeLocalDisk + FakeAudioEngine 测试覆盖导入与点播命令
