# Android + Windows 跨端音乐播放器技术栈对比

> 调研 ticket #6，供 #3 技术栈选型引用。  
> 目标场景：客户端维护曲库语义，扁平化上传 store/server；播放经 file-access JWT + HTTP Range 流式拉取。

## 评估维度说明

| 维度 | 本项目关注点 |
|------|-------------|
| 音频/后台播放 | Android 前台服务 + 通知栏/锁屏控件；Windows 系统媒体传输控件 SMTC |
| 本地文件/MP3 导入 | 文件夹扫描、单文件选择、元数据解析 |
| HTTP Range 流式 | 带 JWT 请求头、可 seek、server 代理 Range |
| 代码共享 | UI + 曲库逻辑 + 同步协议的可复用比例 |
| 包体积/性能 | 安装包大小、冷启动、列表滚动与 seek 延迟 |
| 维护成本 | 生态活跃度、双端 API 一致性、升级与排障难度 |

## 总览对比

| 方案 | 音频/后台 | 本地导入 | Range 流式 | 代码共享 | 包体积 | 维护 | 综合 |
|------|:--------:|:--------:|:----------:|:--------:|:------:|:----:|:----:|
| **Flutter 单仓** | ★★★★☆ | ★★★★☆ | ★★★★★ | ★★★★★ | ★★★☆☆ | ★★★★☆ | **首选候选** |
| **KMP + 各端 UI** | ★★★☆☆ | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | ★★★★☆ | ★★★☆☆ | 偏 Kotlin 团队 |
| **.NET MAUI** | ★★★☆☆ | ★★★★☆ | ★★★☆☆ | ★★★★☆ | ★★☆☆☆ | ★★☆☆☆ | Android 运行时偏重 |
| **Tauri + 原生音频** | ★★☆☆☆ | ★★★☆☆ | ★★★☆☆ | ★★☆☆☆ | ★★★★☆ | ★★☆☆☆ | 双端音频分裂 |
| **双原生 + 共享同步层** | ★★★★★ | ★★★★★ | ★★★★★ | ★★☆☆☆ | ★★★★★ | ★★☆☆☆ | 平台体验最佳、人力最高 |

评分基于 2025–2026 年公开文档与社区实践，★ 为相对优劣，非绝对分值。

---

## 1. Flutter 单仓双端

### 音频与后台播放

- **播放**：[`just_audio`](https://pub.dev/packages/just_audio) 支持 Android、Windows 的 URL/文件/字节流；Windows 经 miniaudio 等原生后端。
- **后台**：[`just_audio_background`](https://pub.dev/packages/just_audio_background) 或 [`audio_service`](https://pub.dev/packages/audio_service) 封装 Android 前台服务、MediaSession、通知栏与锁屏控件。
- **Windows SMTC**：社区有 `smtc_windows` 等插件，成熟度低于 Android 侧，需单独集成与测试。
- **风险**：Android 后台需正确配置 Manifest 前台服务与 `AudioServiceActivity`；配置错误会导致后台约 10 分钟后被系统回收。

### 本地文件与 MP3 导入

- `file_picker`、`permission_handler`、`path_provider` 覆盖双端选文件与目录访问。
- 元数据：`flutter_media_metadata`、`audiotags` 等可解析 ID3；文件夹递归扫描在 Dart 层实现即可。
- Android 11+ 分区存储需 SAF 或 `MANAGE_EXTERNAL_STORAGE` 策略，与原生相同约束。

### HTTP Range 流式

- `just_audio` 文档明确要求服务端支持 Range；seek 时会发起字节范围请求。
- 支持自定义 HTTP 请求头，可携带 file-access JWT。
- 双端 Range 行为一致，由同一 Dart API 驱动，是本项目的**最强项**。

### 代码共享与效率

- UI、曲库模型、同步协议、播放队列逻辑可 **80–95%** 共享。
- 单语言 Dart、热重载、Widget 测试；与 map 偏好「框架现成、代码量最少」高度吻合。

### 包体积与性能

- Android release APK 通常 **15–25 MB** 起（含 Flutter engine）。
- Windows 可执行包 **20–40 MB** 量级。
- 音频解码走原生，列表 UI 60fps 可达；首次启动略慢于纯原生。

### 生态与维护

- Google 持续投入，pub.dev 音频生态成熟。
- 主要维护面：Android 后台配置、Windows SMTC 插件选型、大库 UI 性能调优。

---

## 2. Kotlin Multiplatform + 各端 UI

### 音频与后台播放

- **Android**：Media3/ExoPlayer + `MediaSessionService`，业界最成熟的后台播放栈。
- **Windows**：无官方跨端音频 API。可选 [Klarinet](https://github.com/vectencia/Klarinet)（miniaudio/WASAPI）、[ComposeMediaPlayer-audio](https://klibs.io/project/kdroidFilter/ComposeMediaPlayer) 等第三方库；**后台与 SMTC 需自行对接**。
- **UI**：Compose Multiplatform 可共享 Android + Desktop UI，但 Desktop 音频与媒体控件仍偏 fragmented。

### 本地文件与 MP3 导入

- Android：`MediaStore`、SAF、WorkManager 扫描均为原生一等能力。
- Windows：Java/Kotlin JVM 的 `java.nio.file` 或 Compose Desktop 文件对话框；MP3 元数据可用 taglib 等多平台库。
- 共享层可用 Okio、kotlinx-io 抽象 I/O。

### HTTP Range 流式

- Android ExoPlayer **原生支持** Range 与自定义 Header，与 server 契约匹配最好。
- Windows 侧取决于所选播放器：Klarinet/rodio 系支持 HTTP 流，Range + JWT 需在共享层封装并**逐库验证** seek 行为。

### 代码共享与效率

- 曲库领域、同步协议、网络层可 **50–70%** 共享（`commonMain`）。
- UI 若用 Compose Multiplatform 可再提高；若 Windows 用 WinUI 则 UI 几乎不共享。
- 双端音频接口需 `expect/actual` 或接口 + 平台实现，样板代码多于 Flutter。

### 包体积与性能

- Android 无额外 VM，包体通常 **小于 Flutter**。
- Windows JVM 或 Kotlin/Native 产物中等；性能接近原生。

### 生态与维护

- KMP 核心稳定，JetBrains 持续投入。
- **音频与 Desktop 媒体会话**生态分散，长期维护成本高于 Flutter 单栈。
- 适合已深度 Kotlin/Android、愿意接受 Windows 音频自研的团队。

---

## 3. .NET MAUI

### 音频与后台播放

- [CommunityToolkit.Maui.MediaElement](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement) 基于 ExoPlayer（Android）与 Windows 原生媒体栈。
- Android 后台需 `UseMauiCommunityToolkitMediaElement(isAndroidForegroundServiceEnabled: true)` 开启前台服务。
- Windows 后台播放文档说明**无需额外配置**；SMTC 集成随 Windows 媒体栈，但 MAUI 封装层偶发 Windows 播放回归（社区 issue 可见）。
- 纯音频场景另有 Plugin.Maui.Audio，与 MediaElement 职责重叠，需选型。

### 本地文件与 MP3 导入

- `FilePicker`、`FileSystem` API 跨平台可用。
- MP3 元数据需引入 TagLib# 等 NuGet；文件夹扫描在 C# 层实现。

### HTTP Range 流式

- MediaElement 支持 URI 源；Android 走 ExoPlayer 可 Range。
- **自定义 JWT Header** 支持有限，社区常见做法为预签名 URL 或平台特定 handler，不如 Flutter/Kotlin 原生灵活。
- Windows 侧 Range seek 依赖 MediaElement Windows 后端，需针对 server 契约做集成测试。

### 代码共享与效率

- UI + 业务 **60–80%** 共享（XAML/MAUI）。
- 需 Visual Studio / .NET SDK  toolchain；Android 需 .NET for Android 运行时。

### 包体积与性能

- Android 附带 **.NET 运行时**，安装包常 **30–50 MB+**，为本表最大。
- 冷启动与内存占用高于 Flutter/Kotlin 原生。

### 生态与维护

- MAUI 跨平台社区规模小于 Flutter；GitHub issue 与第三方库更新节奏偏慢。
- 若团队无现有 .NET 资产，学习曲线与包体 penalty 不划算。

---

## 4. Tauri + 原生音频插件

### 架构要点

- **Tauri 2** 同时支持 Windows（WebView2）与 Android（WebView），UI 用 Web 技术。
- **音频不能依赖 WebView  alone**：Android 需 [tauri-plugin-native-audio](https://github.com/uvarov-frontend/tauri-plugin-native-audio)（ExoPlayer）；该插件**不支持 Windows**。
- Windows 播放需 Web Audio API、Rust 侧 rodio/miniaudio 插件，或另写 Tauri command — **双端音频实现分裂**。
- Android 后台：`tauri-plugin-native-audio` 提供前台服务；Windows SMTC **无现成 Tauri 插件**（`tauri-plugin-media-session` 仅 Android/iOS）。

### 本地文件与 MP3 导入

- Tauri FS / dialog 插件可访问本地路径；Android 受 WebView 沙箱与权限模型约束，深层目录扫描不如原生直接。
- MP3 元数据可在 Rust 或 JS 层用第三方库解析。

### HTTP Range 流式

- Android 原生插件走 ExoPlayer，Range 可行。
- Windows 若用 Web Audio / fetch 流，Range 与 seek 行为需自行验证；Rust rodio 支持 HTTP 但 JWT Header 与 seek 表需额外封装。

### 代码共享与效率

- **UI 与同步协议**可共享（TS/Rust）。
- **音频层双端两套**，实际共享比例 **30–50%**，低于名义上的「一套 Web UI」。

### 包体积与性能

- Windows 安装包小（**~5–10 MB** 量级，WebView2 系统自带）。
- Android Tauri 产物中等；WebView 层增加内存与启动开销。

### 生态与维护

- Tauri 桌面生态成熟，**移动端与跨端音频仍快速演进**。
- 音乐播放器需维护 Rust 插件 + JS 桥 + 双端音频差异，**不符合「代码量最少」偏好**。

---

## 5. 双原生 + 共享同步层

### 架构要点

- **Android**：Kotlin + Jetpack Compose + Media3/ExoPlayer + Room。
- **Windows**：C# WinUI 3 / WinAppSDK + `MediaPlayer` 或 WASAPI + SQLite。
- **共享层**：Rust/Kotlin/TypeScript 库，仅含扁平化清单格式、JWT 刷新、上传/下载协议、冲突合并规则；**不含 UI 与播放**。

### 音频与后台播放

- **各平台最优**：ExoPlayer + MediaSession（Android）；`SystemMediaTransportControls` + `MediaPlayer`（Windows）。
- 系统媒体控件、蓝牙键、通知栏行为与 OS 一致，无跨端抽象折中。

### 本地文件与 MP3 导入

- 双端均使用平台原生文件 API 与后台扫描 Job，体验与权限处理最完整。

### HTTP Range 流式

- ExoPlayer 与 Windows `MediaPlayer`/`HttpClient` 均原生支持 Range；JWT 通过 `DataSource` 工厂或 `HttpClient` DefaultRequestHeaders 注入，**可控性最高**。

### 代码共享与效率

- 同步协议层可 **100%** 共享（若用 Rust cinterop / UniFFI 或 Kotlin JS/WASM 等）。
- UI、播放、导入、设置等 **几乎 0 共享**；估算总代码 **仅 20–35%** 复用。
- 两套应用 = 双倍功能开发与双端 UI 一致性成本。

### 包体积与性能

- 各端最小、性能最佳；无跨端运行时 tax。

### 生态与维护

- 平台文档与 Stack Overflow 资源最丰富。
- **人力与发布节奏**成本最高：两个 bug 池、两套 UI 规范、功能 parity 需持续对齐。
- 适合对原生体验要求极高、团队已有双端人力、或 MVP 后长期演进的组织。

---

## 与项目约束的映射

| 约束（来自 #1 map） | Flutter | KMP | MAUI | Tauri | 双原生 |
|--------------------|---------|-----|------|-------|--------|
| server Range + JWT 播放 | ✅ 成熟 | Android ✅ / Win 需验证 | 可行，Header 弱 | 双端分裂 | ✅ 最佳 |
| 曲库扁平化 + 同步 | Dart 单仓 | commonMain | C# 共享 | TS/Rust | 独立共享库 |
| 代码量最少 | ✅ | △ | △ | ✗ | ✗ |
| 框架现成 | ✅ | △ | △ | △ | ✗ |
| 仅 Android + Windows | ✅ 官方支持 | ✅ Desktop target | ✅ | ✅ 但音频分裂 | ✅ |

---

## 结论（供 #3 选型）

1. **默认推荐 Flutter 单仓**：在「代码量最少 + 框架现成」约束下，Range/JWT 流式与双端 UI 共享收益最大；主要补齐项为 Windows SMTC 与 Android 后台 Manifest 配置。
2. **Kotlin 团队备选 KMP**：若团队 Kotlin 优先且接受 Windows 音频/SMTC 自研，可共享领域与同步层，UI 用 Compose Multiplatform。
3. **不推荐 MAUI / Tauri** 作为首版：前者 Android 包体与生态；后者双端音频架构分裂，与播放器核心需求冲突。
4. **双原生 + 共享同步层** 保留为「平台体验优先、人力充足」时的升级路径，而非 MVP 默认。

---

## 参考资料

- [just_audio — Range 与平台矩阵](https://pub.dev/packages/just_audio)
- [just_audio_background — Android 后台配置](https://pub.dev/packages/just_audio_background)
- [Klarinet — KMP 跨平台音频](https://github.com/vectencia/Klarinet)
- [CommunityToolkit.Maui.MediaElement](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement)
- [tauri-plugin-native-audio — 仅 Android/iOS](https://github.com/uvarov-frontend/tauri-plugin-native-audio)
- [Android Media3 / ExoPlayer](https://developer.android.com/media/media3)
