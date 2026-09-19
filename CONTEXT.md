# 客户端曲库

跨平台音乐播放器在设备上维护的个人曲库语义。二进制音频与可选封面、歌词文件同步至 store/server 通用文件 API；元数据与关系仅存于客户端。

## Language

**Song**:
曲库中的一首可播放条目，对应一条元数据记录与一份音频来源。
_Avoid_: Track, 歌曲实体混用中英

**Artist**:
歌手实体，用于歌手视图与 Song 的主歌手关联。
_Avoid_: Singer, 表演者

**Album**:
专辑实体，聚合 Song；每首 Song 在 v1 仅归属一张 Album。
_Avoid_: 唱片, 合集作为 Album 别名

**Album Artist**:
专辑级艺术家，用于区分精选集与 Various Artists 场景。
_Avoid_: 专辑歌手字段与主 Singer 混为一谈

**Cover**:
专辑封面，挂在 Album 上，可对应 server 上的封面 file 与本地缓存。
_Avoid_: 将封面仅当作 Song 内嵌字段

**Lyrics**:
歌词，挂在 Song 上；可为内嵌标签或 sidecar 文件。
_Avoid_: 将歌词建模为独立 Album 级实体

**audioFileId**:
store/server 为 Song 音频分配的文件 UUID。
_Avoid_: file_id 在领域叙述中与 Song 本地 id 混用

**coverFileId**:
store/server 为 Album 封面上传的文件 UUID，可选。
_Avoid_: 封面 file 与 audioFileId 混用

**lyricsFileId**:
store/server 为 Song 歌词 sidecar 上传的文件 UUID，可选；纯内嵌歌词可无此 id。
_Avoid_: 歌词 file 与 audioFileId 混用

**SyncState**:
元数据或资源相对 server 的同步状态：synced、dirty、pendingDelete。
_Avoid_: 用泛化 status 代替 SyncState

**Manifest**:
上传至 store/server 的 JSON 文件，序列化完整 Artist、Album、Song 图及其 file_id 与 updatedAt。
_Avoid_: 清单, catalog, 同步包

**manifestFileId**:
当前有效 Manifest 在 server 上的 file_id，本地记下；新版本上传成功后删除上一份。
_Avoid_: 与 Song 本地 id 混用

**Queue**:
当前设备上的播放序列，有序的 Song id 列表，本机持久化，不进入 Manifest。
_Avoid_: 播放列表, Playlist

**Favorites**:
用户唯一的收藏列表，有序的 Song id 列表，写入 Manifest 随曲库同步。
_Avoid_: 播放列表, 喜欢, 红心

