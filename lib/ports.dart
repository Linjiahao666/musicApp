import 'package:music_app/models.dart';

/// store/server 文件与鉴权端口。
abstract interface class StoreFiles {
  Future<AuthTokens> register({
    required String username,
    required String password,
  });

  Future<AuthTokens> login({
    required String username,
    required String password,
  });

  Future<AuthTokens> refresh({required String refreshToken});

  Future<void> logout({
    required String accessToken,
    String? refreshToken,
  });

  Future<AuthUser> me({required String accessToken});

  /// 上传文件并返回元数据。不大于直传上限时走直传，否则分片。
  Future<StoreFile> uploadFile({
    required String accessToken,
    required String filename,
    required String contentType,
    required List<int> bytes,
  });

  /// 按 file_id 删除 server 上的文件。
  Future<void> deleteFile({
    required String accessToken,
    required String fileId,
  });

  /// 按文件名精确匹配列出当前用户文件，服务端按创建时间降序，可限制条数。
  Future<List<StoreFile>> listFiles({
    required String accessToken,
    required String filename,
    int limit = 1,
  });

  /// 下载文件完整内容。
  Future<List<int>> downloadFile({
    required String accessToken,
    required String fileId,
  });

  /// 签发文件访问令牌，仅用于下载文件内容。
  Future<String> issueFileAccessToken({
    required String accessToken,
    required String fileId,
  });

  /// 文件内容地址，供云端按字节范围播放。
  String fileContentUrl(String fileId);

  /// 使用文件访问令牌按字节范围下载内容。
  Future<List<int>> downloadRange({
    required String fileAccessToken,
    required String fileId,
    String range = 'bytes=0-',
  });
}

/// 本机曲库目录与缓存端口。
abstract interface class LocalDisk {
  Future<void> saveAuthTokens(AuthTokens tokens);

  Future<AuthTokens?> loadAuthTokens();

  Future<void> clearAuthTokens();

  /// 应用曲库目录路径。
  String get libraryPath;

  /// 将源音频拷入应用曲库目录，返回曲库内路径。
  Future<String> copyIntoLibrary(String sourcePath);

  /// 列出应用曲库内的音频路径。
  Future<List<String>> listLibraryPaths();

  /// 读取本机文件字节，供上传音频与 Cover。
  Future<List<int>> readBytes(String path);

  /// 源文件内容哈希，用于导入去重。
  Future<String> contentHash(String path);

  /// 读取源音频的 ID3 或 Vorbis 标签。
  Future<AudioTags> readTags(String path);

  /// 读取与音频同目录的歌词 sidecar。无文件时为空。
  Future<String?> readSidecarLyrics(String audioPath);

  /// 将封面写入 Cover 目录，压成最长边不超过 maxSide 的 JPEG。
  Future<String?> saveCover({
    required String albumId,
    required List<int> bytes,
    int maxSide = coverLongestSide,
  });

  /// 递归列出目录下常见音频扩展名的文件。
  Future<List<String>> listAudioFiles(String folderPath);

  /// 路径是否为目录，供拖拽导入区分文件夹。
  Future<bool> isDirectory(String path);

  /// 将曲库快照写入本机。
  Future<void> saveLibrary(LibrarySnapshot snapshot);

  /// 读取本机曲库快照。无记录时为空。
  Future<LibrarySnapshot?> loadLibrary();

  /// 将有序 Song id 的 Queue 与播放游标写入本机。
  Future<void> saveQueue(QueueState state);

  /// 读取本机 Queue。无记录时为空。
  Future<QueueState?> loadQueue();

  /// 路径是否存在可读文件。
  Future<bool> exists(String path);

  /// 将音频写入缓存目录并返回路径。
  Future<String> writeAudioCache({
    required String songId,
    required String extension,
    required List<int> bytes,
  });

  /// 删除本机路径上的文件。
  Future<void> deletePath(String path);
}

/// 播放引擎端口。
abstract interface class AudioEngine {
  Future<void> setLocalSource(String path);

  Future<void> setRemoteSource({
    required String url,
    Map<String, String> headers = const <String, String>{},
  });

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Duration get position;

  Duration? get duration;

  bool get playing;

  Stream<Duration> get positionStream;

  Future<void> setRepeatMode(RepeatMode mode);

  RepeatMode get repeatMode;

  Future<void> setShuffleEnabled(bool enabled);

  bool get shuffleEnabled;

  /// 当前源播放完毕。
  Stream<void> get completed;
}
