import 'dart:async';

import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';
import 'package:path/path.dart' as p;

final class FakeStoreFiles implements StoreFiles {
  FakeStoreFiles({
    this.accessTtl = const Duration(seconds: accessExpiresInSeconds),
  });

  final Duration accessTtl;
  bool failRefresh = false;
  bool failListFiles = false;
  int refreshCount = 0;

  final Map<String, String> _passwords = <String, String>{};
  final Map<String, String> _userIds = <String, String>{};
  final Map<String, _IssuedAccess> _access = <String, _IssuedAccess>{};
  final Map<String, String> _refreshOwner = <String, String>{};
  final List<FakeUploadedFile> uploads = <FakeUploadedFile>[];
  final List<String> deletedFileIds = <String>[];
  final List<FakeRangeRequest> rangeRequests = <FakeRangeRequest>[];
  final Map<String, String> _fileAccess = <String, String>{};
  int _seq = 0;

  void putFile({
    required String id,
    required String filename,
    required List<int> bytes,
    String contentType = 'audio/mpeg',
  }) {
    uploads.add(
      FakeUploadedFile(
        id: id,
        filename: filename,
        contentType: contentType,
        bytes: List<int>.of(bytes),
        multipart: bytes.length > directUploadMaxBytes,
      ),
    );
  }

  @override
  Future<AuthTokens> register({
    required String username,
    required String password,
  }) async {
    if (_passwords.containsKey(username)) {
      throw const AuthException(
        code: 'AUTH_USERNAME_TAKEN',
        message: 'username taken',
      );
    }
    _rememberUser(username, password);
    return _issue(username);
  }

  @override
  Future<AuthTokens> login({
    required String username,
    required String password,
  }) async {
    final String? stored = _passwords[username];
    if (stored == null) {
      _rememberUser(username, password);
    } else if (stored != password) {
      throw const AuthException(
        code: 'AUTH_INVALID_CREDENTIALS',
        message: 'invalid credentials',
      );
    }
    return _issue(username);
  }

  @override
  Future<AuthTokens> refresh({required String refreshToken}) async {
    refreshCount += 1;
    if (failRefresh) {
      throw const AuthException(
        code: 'AUTH_INVALID_TOKEN',
        message: 'refresh failed',
      );
    }
    final String? username = _refreshOwner[refreshToken];
    if (username == null) {
      throw const AuthException(
        code: 'AUTH_INVALID_TOKEN',
        message: 'invalid refresh',
      );
    }
    return _issue(username, refreshToken: refreshToken);
  }

  @override
  Future<void> logout({
    required String accessToken,
    String? refreshToken,
  }) async {
    _access.remove(accessToken);
    if (refreshToken != null) {
      _refreshOwner.remove(refreshToken);
    }
  }

  @override
  Future<AuthUser> me({required String accessToken}) async {
    final _IssuedAccess issued = _requireAccess(accessToken);
    return AuthUser(id: issued.userId, username: issued.username);
  }

  @override
  Future<StoreFile> uploadFile({
    required String accessToken,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) async {
    _requireAccess(accessToken);
    _seq += 1;
    final String id = 'file-$_seq';
    final FakeUploadedFile uploaded = FakeUploadedFile(
      id: id,
      filename: filename,
      contentType: contentType,
      bytes: List<int>.of(bytes),
      multipart: bytes.length > directUploadMaxBytes,
    );
    uploads.add(uploaded);
    return StoreFile(
      id: id,
      filename: filename,
      contentType: contentType,
      sizeBytes: bytes.length,
    );
  }

  @override
  Future<void> deleteFile({
    required String accessToken,
    required String fileId,
  }) async {
    _requireAccess(accessToken);
    deletedFileIds.add(fileId);
  }

  @override
  Future<List<StoreFile>> listFiles({
    required String accessToken,
    required String filename,
    int limit = 1,
  }) async {
    _requireAccess(accessToken);
    if (failListFiles) {
      throw const AuthException(code: 'STORE_REQUEST_FAILED', message: '请求失败');
    }
    final List<FakeUploadedFile> matched = <FakeUploadedFile>[
      for (final FakeUploadedFile file in uploads.reversed)
        if (file.filename == filename && !deletedFileIds.contains(file.id)) file,
    ];
    final int end = limit < matched.length ? limit : matched.length;
    return <StoreFile>[
      for (final FakeUploadedFile file in matched.take(end))
        StoreFile(
          id: file.id,
          filename: file.filename,
          contentType: file.contentType,
          sizeBytes: file.bytes.length,
        ),
    ];
  }

  @override
  Future<List<int>> downloadFile({
    required String accessToken,
    required String fileId,
  }) async {
    _requireAccess(accessToken);
    if (deletedFileIds.contains(fileId)) {
      throw const AuthException(code: 'FILE_NOT_FOUND', message: 'file not found');
    }
    for (final FakeUploadedFile file in uploads) {
      if (file.id == fileId) {
        return List<int>.of(file.bytes);
      }
    }
    throw const AuthException(code: 'FILE_NOT_FOUND', message: 'file not found');
  }

  @override
  Future<String> issueFileAccessToken({
    required String accessToken,
    required String fileId,
  }) async {
    _requireAccess(accessToken);
    _requireUploaded(fileId);
    _seq += 1;
    final String token = 'file-access-$_seq';
    _fileAccess[token] = fileId;
    return token;
  }

  @override
  String fileContentUrl(String fileId) => 'fake://files/$fileId/content';

  @override
  Future<List<int>> downloadRange({
    required String fileAccessToken,
    required String fileId,
    String range = 'bytes=0-',
  }) async {
    if (_fileAccess[fileAccessToken] != fileId) {
      throw const AuthException(
        code: 'AUTH_INVALID_TOKEN',
        message: 'invalid file access',
      );
    }
    rangeRequests.add(
      FakeRangeRequest(
        fileId: fileId,
        range: range,
        fileAccessToken: fileAccessToken,
      ),
    );
    return _sliceRange(_requireUploaded(fileId).bytes, range);
  }

  FakeUploadedFile _requireUploaded(String fileId) {
    if (deletedFileIds.contains(fileId)) {
      throw const AuthException(code: 'FILE_NOT_FOUND', message: 'file not found');
    }
    for (final FakeUploadedFile file in uploads) {
      if (file.id == fileId) {
        return file;
      }
    }
    throw const AuthException(code: 'FILE_NOT_FOUND', message: 'file not found');
  }

  _IssuedAccess _requireAccess(String accessToken) {
    final _IssuedAccess? issued = _access[accessToken];
    if (issued == null) {
      throw const AuthException(
        code: 'AUTH_INVALID_TOKEN',
        message: 'invalid access',
      );
    }
    return issued;
  }

  List<int> _sliceRange(List<int> bytes, String range) {
    if (!range.startsWith('bytes=')) {
      throw const AuthException(
        code: 'RANGE_NOT_SATISFIABLE',
        message: '非法 Range',
      );
    }
    final String spec = range.substring(6);
    if (spec.startsWith('-')) {
      final int suffix = int.parse(spec.substring(1));
      final int start = bytes.length > suffix ? bytes.length - suffix : 0;
      return List<int>.of(bytes.sublist(start));
    }
    final int dash = spec.indexOf('-');
    if (dash < 0) {
      throw const AuthException(
        code: 'RANGE_NOT_SATISFIABLE',
        message: '非法 Range',
      );
    }
    final int start = int.parse(spec.substring(0, dash));
    if (start < 0 || start >= bytes.length) {
      throw const AuthException(
        code: 'RANGE_NOT_SATISFIABLE',
        message: '非法 Range',
      );
    }
    if (dash == spec.length - 1) {
      return List<int>.of(bytes.sublist(start));
    }
    final int end = int.parse(spec.substring(dash + 1));
    final int exclusive = end + 1 > bytes.length ? bytes.length : end + 1;
    return List<int>.of(bytes.sublist(start, exclusive));
  }

  void _rememberUser(String username, String password) {
    _passwords[username] = password;
    _userIds[username] = 'user-$username';
  }

  AuthTokens _issue(String username, {String? refreshToken}) {
    final String? userId = _userIds[username];
    if (userId == null) {
      throw const AuthException(
        code: 'AUTH_INVALID_TOKEN',
        message: 'unknown user',
      );
    }
    _seq += 1;
    final String accessToken = 'access-$_seq';
    final String issuedRefresh = refreshToken ?? 'refresh-$_seq';
    _access[accessToken] = _IssuedAccess(
      username: username,
      userId: userId,
    );
    _refreshOwner[issuedRefresh] = username;
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: issuedRefresh,
      expiresAt: DateTime.now().add(accessTtl),
    );
  }
}

final class _IssuedAccess {
  const _IssuedAccess({
    required this.username,
    required this.userId,
  });

  final String username;
  final String userId;
}

final class FakeUploadedFile {
  const FakeUploadedFile({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.bytes,
    required this.multipart,
  });

  final String id;
  final String filename;
  final String contentType;
  final List<int> bytes;
  final bool multipart;
}

final class FakeRangeRequest {
  const FakeRangeRequest({
    required this.fileId,
    required this.range,
    required this.fileAccessToken,
  });

  final String fileId;
  final String range;
  final String fileAccessToken;
}

final class FakeLocalDisk implements LocalDisk {
  AuthTokens? storedTokens;
  QueueState? storedQueue;
  LibrarySnapshot? storedLibrary;
  final List<String> libraryPaths = <String>[];
  final Map<String, String> hashes = <String, String>{};
  final Map<String, AudioTags> tagsByPath = <String, AudioTags>{};
  final Map<String, String> sidecarLyrics = <String, String>{};
  final Map<String, List<String>> folderAudioFiles = <String, List<String>>{};
  final Set<String> directories = <String>{};
  final Map<String, List<int>> savedCovers = <String, List<int>>{};
  final Map<String, List<int>> fileBytes = <String, List<int>>{};
  final Set<String> deletedPaths = <String>{};
  int? lastCoverMaxSide;

  @override
  String get libraryPath => '/library';

  @override
  Future<void> saveAuthTokens(AuthTokens tokens) async {
    storedTokens = tokens;
  }

  @override
  Future<AuthTokens?> loadAuthTokens() async => storedTokens;

  @override
  Future<void> clearAuthTokens() async {
    storedTokens = null;
  }

  @override
  Future<String> copyIntoLibrary(String sourcePath) async {
    final String dest = '$libraryPath/${p.basename(sourcePath)}';
    if (!libraryPaths.contains(dest)) {
      libraryPaths.add(dest);
    }
    fileBytes[dest] = List<int>.of(fileBytes[sourcePath] ?? const <int>[]);
    deletedPaths.remove(dest);
    return dest;
  }

  @override
  Future<List<String>> listLibraryPaths() async {
    return List<String>.of(libraryPaths);
  }

  @override
  Future<List<int>> readBytes(String path) async {
    return List<int>.of(fileBytes[path] ?? const <int>[]);
  }

  @override
  Future<String> contentHash(String path) async {
    return hashes[path] ?? path;
  }

  @override
  Future<AudioTags> readTags(String path) async {
    return tagsByPath[path] ?? const AudioTags();
  }

  @override
  Future<String?> readSidecarLyrics(String audioPath) async {
    return sidecarLyrics[audioPath];
  }

  @override
  Future<String?> saveCover({
    required String albumId,
    required List<int> bytes,
    int maxSide = coverLongestSide,
  }) async {
    lastCoverMaxSide = maxSide;
    if (bytes.isEmpty) {
      return null;
    }
    savedCovers[albumId] = bytes;
    final String path = '$libraryPath/covers/$albumId.jpg';
    fileBytes[path] = List<int>.of(bytes);
    return path;
  }

  @override
  Future<List<String>> listAudioFiles(String folderPath) async {
    return List<String>.of(folderAudioFiles[folderPath] ?? const <String>[]);
  }

  @override
  Future<bool> isDirectory(String path) async {
    return directories.contains(path);
  }

  @override
  Future<void> saveLibrary(LibrarySnapshot snapshot) async {
    storedLibrary = snapshot;
  }

  @override
  Future<LibrarySnapshot?> loadLibrary() async => storedLibrary;

  @override
  Future<void> saveQueue(QueueState state) async {
    storedQueue = state;
  }

  @override
  Future<QueueState?> loadQueue() async => storedQueue;

  @override
  Future<bool> exists(String path) async {
    if (path.isEmpty || deletedPaths.contains(path)) {
      return false;
    }
    return fileBytes.containsKey(path) || libraryPaths.contains(path);
  }

  @override
  Future<String> writeAudioCache({
    required String songId,
    required String extension,
    required List<int> bytes,
  }) async {
    final String ext =
        extension.isEmpty || extension.startsWith('.') ? extension : '.$extension';
    final String path = '/cache/$songId$ext';
    fileBytes[path] = List<int>.of(bytes);
    deletedPaths.remove(path);
    return path;
  }

  @override
  Future<void> deletePath(String path) async {
    fileBytes.remove(path);
    libraryPaths.remove(path);
    deletedPaths.add(path);
  }
}

final class FakeAudioEngine implements AudioEngine {
  String? localSource;
  String? remoteSource;
  Map<String, String> remoteHeaders = const <String, String>{};

  @override
  bool playing = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? duration = const Duration(minutes: 3);

  @override
  final Stream<Duration> positionStream = Stream<Duration>.empty();

  @override
  Future<void> setLocalSource(String path) async {
    localSource = path;
    remoteSource = null;
    remoteHeaders = const <String, String>{};
    position = Duration.zero;
  }

  @override
  Future<void> setRemoteSource({
    required String url,
    Map<String, String> headers = const <String, String>{},
  }) async {
    remoteSource = url;
    remoteHeaders = headers;
    localSource = null;
    position = Duration.zero;
  }

  @override
  Future<void> play() async {
    playing = true;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
  }

  @override
  RepeatMode repeatMode = RepeatMode.all;

  @override
  bool shuffleEnabled = false;

  final StreamController<void> _completed = StreamController<void>.broadcast();

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    repeatMode = mode;
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    shuffleEnabled = enabled;
  }

  /// 模拟当前源播放完毕。
  void finishCurrent() {
    playing = false;
    _completed.add(null);
  }
}
