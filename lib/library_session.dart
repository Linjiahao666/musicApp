import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:music_app/merge_library.dart';
import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';
import 'package:path/path.dart' as p;

final class LibraryProjection {
  const LibraryProjection({
    this.songs = const <Song>[],
    this.artists = const <Artist>[],
    this.albums = const <Album>[],
  });

  final List<Song> songs;
  final List<Artist> artists;
  final List<Album> albums;

  /// 按标题、歌手名、专辑名子串过滤，并投影剩余 Song 归属的 Artist 与 Album。
  LibraryProjection filtered(String query) {
    final String needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return this;
    }
    return _ofSongs(songs.where((Song song) => _matches(song, needle)).toList());
  }

  /// 可离线播放的投影，排除仅云端且无缓存的 Song。
  LibraryProjection get offline {
    return _ofSongs(<Song>[
      for (final Song song in songs)
        if (!song.needsNetwork) song,
    ]);
  }

  List<Song> songsOfArtist(String artistId) {
    return songs.where((Song song) => song.artistId == artistId).toList();
  }

  List<Song> songsOfAlbum(String albumId) {
    return songs.where((Song song) => song.albumId == albumId).toList();
  }

  Artist artistOf(Song song) {
    return artists.firstWhere((Artist artist) => artist.id == song.artistId);
  }

  Album albumOf(Song song) {
    return albums.firstWhere((Album album) => album.id == song.albumId);
  }

  bool _matches(Song song, String needle) {
    return _contains(song.title, needle) ||
        _contains(artistOf(song).name, needle) ||
        _contains(albumOf(song).title, needle);
  }

  bool _contains(String value, String needle) {
    return value.toLowerCase().contains(needle);
  }

  LibraryProjection _ofSongs(List<Song> matched) {
    final Set<String> albumIds = matched.map((Song song) => song.albumId).toSet();
    final Set<String> artistIds = <String>{
      for (final Song song in matched) ...<String>[
        song.artistId,
        if (song.albumArtistId != null) song.albumArtistId!,
      ],
      for (final Album album in albums)
        if (albumIds.contains(album.id) && album.artistId != null) album.artistId!,
    };
    return LibraryProjection(
      songs: matched,
      artists: artists.where((Artist artist) => artistIds.contains(artist.id)).toList(),
      albums: albums.where((Album album) => albumIds.contains(album.id)).toList(),
    );
  }
}

/// 曲库会话。依赖可替换的 StoreFiles、LocalDisk、AudioEngine。
final class LibrarySession {
  LibrarySession({
    required this.storeFiles,
    required this.localDisk,
    required this.audioEngine,
  }) : _random = Random() {
    audioEngine.completed.listen((_) {
      unawaited(_advanceAfterCompleted());
    });
  }

  final StoreFiles storeFiles;
  final LocalDisk localDisk;
  final AudioEngine audioEngine;
  final Random _random;
  final StreamController<void> _playbackChanged =
      StreamController<void>.broadcast();

  AuthTokens? _tokens;
  AuthUser? _currentUser;
  List<Song> _songs = const <Song>[];
  List<Artist> _artists = const <Artist>[];
  List<Album> _albums = const <Album>[];
  Song? _currentSong;
  List<String> _queueIds = <String>[];
  int _queueIndex = 0;
  Favorites _favorites = Favorites();
  String? _manifestFileId;
  bool _manifestDirty = false;
  int _cacheLimitBytes = defaultAudioCacheLimitBytes;
  int _cacheClock = 0;
  Object? _syncError;

  LibraryProjection get library {
    return LibraryProjection(
      songs: _songs,
      artists: _artists,
      albums: _albums,
    )._ofSongs(<Song>[
      for (final Song song in _songs)
        if (song.syncState != SyncState.pendingDelete) song,
    ]);
  }

  /// 按 id 读取 Song 的 SyncState。
  SyncState? songSyncState(String songId) {
    return _songById(songId)?.syncState;
  }

  /// 按标题、歌手名、专辑名子串过滤当前曲库投影。
  LibraryProjection filter(String query) => library.filtered(query);

  /// 当前登录用户投影。未登录时为空。
  AuthUser? get currentUser => _currentUser;

  /// 当前点播的 Song。
  Song? get currentSong => _currentSong;

  /// 播放源、播放状态或 Queue 游标变化。
  Stream<void> get playbackChanged => _playbackChanged.stream;

  /// 当前设备上的播放序列，有序 Song id。
  List<String> get queue => List<String>.unmodifiable(_queueIds);

  /// 当前播放在 Queue 中的下标。
  int get queueIndex => _queueIndex;

  /// 用户唯一的收藏列表。
  Favorites get favorites => Favorites(
        songIds: List<String>.unmodifiable(_favorites.songIds),
        updatedAt: _favorites.updatedAt,
      );

  /// 当前有效 Manifest 在 server 上的 file_id。
  String? get manifestFileId => _manifestFileId;

  /// 最近一次同步失败。成功后为空。
  Object? get syncError => _syncError;

  /// 音频缓存上限，单位字节。Cover 不计入用量。
  int get cacheLimitBytes => _cacheLimitBytes;

  /// 当前音频缓存占用，不含 Cover。
  int get cacheUsageBytes {
    int used = 0;
    for (final Song song in _songs) {
      if (song.cachedAudioPath.isNotEmpty) {
        used += song.cachedSizeBytes;
      }
    }
    return used;
  }

  /// 可离线播放的曲库投影。
  LibraryProjection get offlineLibrary => library.offline;

  /// Song 是否已在 Favorites 中。
  bool isFavorite(String songId) => _favorites.songIds.contains(songId);

  /// 按 Favorites 顺序取出当前曲库中的 Song。
  List<Song> favoriteSongs([LibraryProjection? projection]) {
    final List<Song> songs = (projection ?? library).songs;
    final Map<String, Song> byId = <String, Song>{
      for (final Song song in songs) song.id: song,
    };
    return <Song>[
      for (final String id in _favorites.songIds)
        if (byId[id] case final Song song) song,
    ];
  }

  /// 将单个音频拷入应用曲库并投影到歌曲列表。
  Future<ImportResult> importFile(String sourcePath) {
    return _importSources(<String>[sourcePath]);
  }

  /// 递归导入文件夹内常见音频。
  Future<ImportResult> importFolder(String folderPath) async {
    return _importSources(await localDisk.listAudioFiles(folderPath));
  }

  /// 导入拖拽的文件与文件夹路径。
  Future<ImportResult> importDropped(List<String> paths) async {
    final List<String> sources = <String>[];
    for (final String path in paths) {
      if (await localDisk.isDirectory(path)) {
        sources.addAll(await localDisk.listAudioFiles(path));
      } else {
        sources.add(path);
      }
    }
    return _importSources(sources);
  }

  /// 按本机文件路径点播。
  Future<void> playSong(Song song) {
    return playFromView(<Song>[song], song);
  }

  /// 用当前视图整表替换 Queue，并从点中项开始播放。
  Future<void> playFromView(List<Song> view, Song start) async {
    if (view.isEmpty) {
      return;
    }
    _queueIds = <String>[for (final Song song in view) song.id];
    final int index = _queueIds.indexOf(start.id);
    await _playAt(index < 0 ? 0 : index);
  }

  /// 将 Song 插到当前项之后，不改动其余 Queue 顺序。
  Future<void> playNext(Song song) async {
    if (_queueIds.isEmpty) {
      _queueIds = <String>[song.id];
      _queueIndex = 0;
    } else {
      _queueIds.insert(_queueIndex + 1, song.id);
    }
    await _persistQueue();
  }

  /// 将 Song 加到 Queue 队尾。
  Future<void> appendToQueue(Song song) async {
    _queueIds.add(song.id);
    await _persistQueue();
  }

  /// 将 Song 追加到 Favorites 末尾。已在列表中则保持原顺序。
  Future<void> addToFavorites(Song song) async {
    if (_favorites.songIds.contains(song.id)) {
      return;
    }
    _favorites = Favorites(
      songIds: <String>[..._favorites.songIds, song.id],
      updatedAt: DateTime.now(),
    );
    await _persistLibrary();
  }

  /// 从 Favorites 移出该 Song id，其余顺序不变。
  Future<void> removeFromFavorites(Song song) async {
    if (!_favorites.songIds.contains(song.id)) {
      return;
    }
    _dropFavoriteId(song.id);
    await _persistLibrary();
  }

  /// 单首改标题、主歌手；专辑名改写该 Song 所属 Album。
  Future<void> editSong(
    Song song, {
    String? title,
    String? artistName,
    String? albumTitle,
  }) async {
    final Song? current = _songById(song.id);
    if (current == null || current.syncState == SyncState.pendingDelete) {
      return;
    }
    _replaceSong(_withArtist(_withTitle(current, title), artistName));
    _renameAlbum(current.albumId, albumTitle);
    await _persistLibrary();
  }

  /// 从曲库列表移除 Song，并标记 pendingDelete。
  Future<void> deleteSong(Song song) async {
    final Song? current = _songById(song.id);
    if (current != null && current.cachedAudioPath.isNotEmpty) {
      await localDisk.deletePath(current.cachedAudioPath);
    }
    _markPendingDelete(song.id);
    if (_currentSong?.id == song.id) {
      _currentSong = null;
      await audioEngine.pause();
      _emitPlayback();
    }
    _dropQueueId(song.id);
    _dropFavoriteId(song.id);
    await _persistLibrary();
    await _persistQueue();
  }

  /// 调整音频缓存上限并立即淘汰超额项。
  Future<void> setCacheLimitBytes(int bytes) async {
    _cacheLimitBytes = bytes < 0 ? 0 : bytes;
    await _evictOverflow();
    await _persistLocalState();
  }

  /// 固定下载该 Song，缓存不参与淘汰。
  Future<void> pinDownload(Song song) async {
    final Song? current = _songById(song.id);
    if (current == null || current.syncState == SyncState.pendingDelete) {
      return;
    }
    final Song pinned = current.copyWith(isPinnedDownload: true);
    _replaceSong(pinned);
    if (!await _hasPlayableAudio(pinned)) {
      await _fillRemoteCache(pinned);
    }
    await _persistLocalState();
  }

  /// 取消固定下载，并按上限淘汰超额缓存。
  Future<void> unpinDownload(Song song) async {
    final Song? current = _songById(song.id);
    if (current == null || !current.isPinnedDownload) {
      return;
    }
    _replaceSong(current.copyWith(isPinnedDownload: false));
    await _evictOverflow();
    await _persistLocalState();
  }

  Future<void> skipToNext() async {
    if (_queueIds.isEmpty) {
      return;
    }
    if (audioEngine.shuffleEnabled) {
      await _playAt(_shuffledIndex());
      return;
    }
    await _playAt(_nextIndex());
  }

  Future<void> skipToPrevious() async {
    if (_queueIds.isEmpty) {
      return;
    }
    if (_queueIndex > 0) {
      await _playAt(_queueIndex - 1);
      return;
    }
    await _playAt(_queueIds.length - 1);
  }

  Future<void> setRepeatMode(RepeatMode mode) async {
    await audioEngine.setRepeatMode(mode);
    await _persistQueue();
  }

  Future<void> setShuffleEnabled(bool enabled) async {
    await audioEngine.setShuffleEnabled(enabled);
    await _persistQueue();
  }

  /// 在列表循环、单曲循环、随机之间切换。随机不打乱 Queue 顺序。
  Future<void> cyclePlaybackMode() async {
    if (audioEngine.shuffleEnabled) {
      await audioEngine.setShuffleEnabled(false);
      await audioEngine.setRepeatMode(RepeatMode.all);
    } else if (audioEngine.repeatMode == RepeatMode.all) {
      await audioEngine.setRepeatMode(RepeatMode.one);
    } else {
      await audioEngine.setRepeatMode(RepeatMode.all);
      await audioEngine.setShuffleEnabled(true);
    }
    await _persistQueue();
  }

  Future<void> play() async {
    await audioEngine.play();
    _emitPlayback();
  }

  Future<void> pause() async {
    await audioEngine.pause();
    await _persistQueue();
    _emitPlayback();
  }

  Future<void> seek(Duration position) async {
    await audioEngine.seek(position);
    await _persistQueue();
    _emitPlayback();
  }

  /// 从本机恢复凭证，Access 过期则 refresh。
  Future<void> restoreSession() async {
    await _reloadLibrary();
    final AuthTokens? stored = await localDisk.loadAuthTokens();
    if (stored != null) {
      _tokens = stored;
      try {
        await _loadUser();
      } catch (_) {
        await _forget();
      }
    }
    await _restoreQueue();
    await _trySync();
  }

  Future<void> register({
    required String username,
    required String password,
  }) async {
    await _acceptTokens(
      await storeFiles.register(username: username, password: password),
    );
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    await _acceptTokens(
      await storeFiles.login(username: username, password: password),
    );
  }

  Future<void> logout() async {
    final AuthTokens? tokens = _tokens;
    if (tokens != null) {
      try {
        await _ensureAccess();
        final AuthTokens current = _requireTokens();
        await storeFiles.logout(
          accessToken: current.accessToken,
          refreshToken: current.refreshToken,
        );
      } catch (_) {
        // 本机凭证仍须清除。
      }
    }
    await _forget();
  }

  Future<void> _acceptTokens(AuthTokens tokens) async {
    _tokens = tokens;
    await localDisk.saveAuthTokens(tokens);
    try {
      await _loadUser();
    } catch (_) {
      await _forget();
      rethrow;
    }
    await _trySync();
  }

  Future<void> _loadUser() async {
    await _ensureAccess();
    final AuthUser user = await storeFiles.me(accessToken: _requireTokens().accessToken);
    _currentUser = user;
  }

  Future<void> _ensureAccess() async {
    final AuthTokens tokens = _requireTokens();
    if (!tokens.isExpired) {
      return;
    }
    try {
      final AuthTokens refreshed = await storeFiles.refresh(
        refreshToken: tokens.refreshToken,
      );
      _tokens = refreshed;
      await localDisk.saveAuthTokens(refreshed);
    } on AuthException {
      await _forget();
      rethrow;
    }
  }

  AuthTokens _requireTokens() {
    final AuthTokens? tokens = _tokens;
    if (tokens == null) {
      throw const AuthException(code: 'AUTH_INVALID_TOKEN', message: '未登录');
    }
    return tokens;
  }

  Future<void> _forget() async {
    _tokens = null;
    _currentUser = null;
    _syncError = null;
    await localDisk.clearAuthTokens();
  }

  /// 登录且有网时先拉取远端 Manifest 做 LWW 合并，再上传 dirty 资源与全量 Manifest。
  Future<void> sync() async {
    if (_currentUser == null) {
      return;
    }
    await _ensureAccess();
    final String accessToken = _requireTokens().accessToken;
    await _pullRemote(accessToken);
    await _deletePendingBlobs(accessToken);
    if (!_manifestDirty) {
      return;
    }
    await _uploadDirtyAudio(accessToken);
    await _uploadDirtyCovers(accessToken);
    await _uploadDirtyLyrics(accessToken);
    _markSynced();
    await _replaceManifest(accessToken);
    await _saveSnapshot(manifestDirty: false);
  }

  Future<void> _pullRemote(String accessToken) async {
    final (LibrarySnapshot remote, String? remoteId) =
        await _loadRemoteManifest(accessToken);
    final LibrarySnapshot merged = mergeLibrary(_librarySnapshot(), remote);
    _songs = List<Song>.of(merged.songs);
    _artists = List<Artist>.of(merged.artists);
    _albums = List<Album>.of(merged.albums);
    _favorites = Favorites(
      songIds: List<String>.of(merged.favorites.songIds),
      updatedAt: merged.favorites.updatedAt,
    );
    if (remoteId != null) {
      _manifestFileId = remoteId;
    }
    final String? currentId = _currentSong?.id;
    if (currentId != null) {
      final Song? live = _songById(currentId);
      if (live == null || live.syncState == SyncState.pendingDelete) {
        _currentSong = null;
        await audioEngine.pause();
      } else {
        _currentSong = live;
      }
    }
    final bool pruned = _pruneQueueOfPendingDelete();
    await localDisk.saveLibrary(_librarySnapshot());
    if (pruned) {
      await _persistQueue();
    }
  }

  Future<(LibrarySnapshot, String?)> _loadRemoteManifest(String accessToken) async {
    final List<StoreFile> items = await storeFiles.listFiles(
      accessToken: accessToken,
      filename: manifestFilename,
      limit: 1,
    );
    if (items.isEmpty) {
      return (LibrarySnapshot(), null);
    }
    final List<int> bytes = await storeFiles.downloadFile(
      accessToken: accessToken,
      fileId: items.first.id,
    );
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      return (LibrarySnapshot(), null);
    }
    return (LibrarySnapshot.fromJson(decoded), items.first.id);
  }

  Future<void> _deletePendingBlobs(String accessToken) async {
    final Set<String> liveAlbumIds = <String>{
      for (final Song song in _songs)
        if (song.syncState != SyncState.pendingDelete) song.albumId,
    };
    final Set<String> ids = <String>{};
    for (final Song song in _songs) {
      if (song.syncState != SyncState.pendingDelete) {
        continue;
      }
      if (song.audioFileId case final String id) {
        ids.add(id);
      }
      if (song.lyricsFileId case final String id) {
        ids.add(id);
      }
    }
    for (final Album album in _albums) {
      if (liveAlbumIds.contains(album.id)) {
        continue;
      }
      if (album.coverFileId case final String id) {
        ids.add(id);
      }
    }
    for (final String id in ids) {
      try {
        await storeFiles.deleteFile(accessToken: accessToken, fileId: id);
      } catch (_) {
        // 远端文件可能已被删除。
      }
    }
  }

  bool _pruneQueueOfPendingDelete() {
    final Set<String> pending = <String>{
      for (final Song song in _songs)
        if (song.syncState == SyncState.pendingDelete) song.id,
    };
    final int before = _queueIds.length;
    for (final String id in pending) {
      _dropQueueId(id);
    }
    return _queueIds.length != before;
  }

  Future<void> _trySync() async {
    try {
      await sync();
      _syncError = null;
    } catch (error) {
      _syncError = error;
      // 后台同步失败不影响本机会话。
    }
  }

  Future<void> _uploadDirtyAudio(String accessToken) async {
    final List<String> ids = <String>[
      for (final Song song in _songs)
        if (song.syncState == SyncState.dirty && song.audioFileId == null)
          song.id,
    ];
    for (final String id in ids) {
      final Song? song = _songById(id);
      if (song == null) {
        continue;
      }
      final String ext = p.extension(song.localAudioPath);
      final StoreFile file = await storeFiles.uploadFile(
        accessToken: accessToken,
        filename: '$id$ext',
        contentType: _audioContentType(ext),
        bytes: await localDisk.readBytes(song.localAudioPath),
      );
      _replaceSong(song.copyWith(audioFileId: file.id));
    }
  }

  Future<void> _uploadDirtyCovers(String accessToken) async {
    final List<String> ids = <String>[
      for (final Album album in _albums)
        if (album.syncState == SyncState.dirty &&
            album.coverFileId == null &&
            album.coverPath != null)
          album.id,
    ];
    for (final String id in ids) {
      final Album? album = _albumById(id);
      final String? coverPath = album?.coverPath;
      if (album == null || coverPath == null) {
        continue;
      }
      final StoreFile file = await storeFiles.uploadFile(
        accessToken: accessToken,
        filename: '$id.jpg',
        contentType: 'image/jpeg',
        bytes: await localDisk.readBytes(coverPath),
      );
      _replaceAlbum(album.copyWith(coverFileId: file.id));
    }
  }

  Future<void> _uploadDirtyLyrics(String accessToken) async {
    final List<String> ids = <String>[
      for (final Song song in _songs)
        if (song.syncState == SyncState.dirty && song.lyricsFileId == null)
          song.id,
    ];
    for (final String id in ids) {
      final Song? song = _songById(id);
      final String? lyrics = song?.lyrics;
      if (song == null || lyrics == null || lyrics.trim().isEmpty) {
        continue;
      }
      final StoreFile file = await storeFiles.uploadFile(
        accessToken: accessToken,
        filename: '$id.lrc',
        contentType: 'text/plain',
        bytes: utf8.encode(lyrics),
      );
      _replaceSong(song.copyWith(lyricsFileId: file.id));
    }
  }

  Future<void> _replaceManifest(String accessToken) async {
    final String? previous = _manifestFileId;
    final StoreFile uploaded = await storeFiles.uploadFile(
      accessToken: accessToken,
      filename: manifestFilename,
      contentType: 'application/json',
      bytes: utf8.encode(jsonEncode(_librarySnapshot().toManifestJson())),
    );
    _manifestFileId = uploaded.id;
    if (previous == null) {
      return;
    }
    try {
      await storeFiles.deleteFile(accessToken: accessToken, fileId: previous);
    } catch (_) {
      // 新 Manifest 已生效。
    }
  }

  void _markSynced() {
    _songs = <Song>[
      for (final Song song in _songs)
        if (song.syncState == SyncState.dirty)
          song.copyWith(syncState: SyncState.synced)
        else
          song,
    ];
    _albums = <Album>[
      for (final Album album in _albums)
        if (album.syncState == SyncState.dirty)
          album.copyWith(syncState: SyncState.synced)
        else
          album,
    ];
    _artists = <Artist>[
      for (final Artist artist in _artists)
        if (artist.syncState == SyncState.dirty)
          artist.copyWith(syncState: SyncState.synced)
        else
          artist,
    ];
    if (_currentSong case final Song current) {
      _currentSong = _songById(current.id);
    }
  }

  String _audioContentType(String ext) {
    return switch (ext.toLowerCase()) {
      '.mp3' => 'audio/mpeg',
      '.flac' => 'audio/flac',
      '.m4a' || '.mp4' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.ogg' || '.opus' => 'audio/ogg',
      '.wav' => 'audio/wav',
      '.wma' => 'audio/x-ms-wma',
      _ => 'application/octet-stream',
    };
  }

  Future<ImportResult> _importSources(List<String> sources) async {
    int imported = 0;
    int duplicates = 0;
    for (final String source in sources) {
      switch (await _importOne(source)) {
        case _ImportOutcome.imported:
          imported += 1;
        case _ImportOutcome.duplicate:
          duplicates += 1;
        case _ImportOutcome.ignored:
          break;
      }
    }
    await _persistLibrary();
    return ImportResult(importedCount: imported, duplicateCount: duplicates);
  }

  Future<_ImportOutcome> _importOne(String sourcePath) async {
    if (!isLibraryAudioPath(sourcePath)) {
      return _ImportOutcome.ignored;
    }
    final String hash = await localDisk.contentHash(sourcePath);
    if (_hasHash(hash)) {
      return _ImportOutcome.duplicate;
    }
    final AudioTags tags = await localDisk.readTags(sourcePath);
    final String? sidecar = await localDisk.readSidecarLyrics(sourcePath);
    final String dest = await localDisk.copyIntoLibrary(sourcePath);
    final Artist artist = _artistNamed(_blankToNull(tags.artist) ?? unknownArtistName);
    final Artist albumArtist = _artistNamed(
      _blankToNull(tags.albumArtist) ?? artist.name,
    );
    final String? albumTitle = _blankToNull(tags.album);
    Album album = _albumNamed(
      title: albumTitle ?? unknownAlbumTitle,
      albumArtistId: albumTitle == null ? unknownArtistId : albumArtist.id,
    );
    album = await _withCover(album, tags.coverBytes);
    final Song song = Song(
      id: _newId(),
      title: _blankToNull(tags.title) ?? p.basename(sourcePath),
      localAudioPath: dest,
      artistId: artist.id,
      albumId: album.id,
      albumArtistId: albumArtist.id,
      trackNumber: tags.trackNumber,
      lyrics: _blankToNull(sidecar) ?? _blankToNull(tags.lyrics),
      contentHash: hash,
    );
    _songs = <Song>[..._songs, song];
    return _ImportOutcome.imported;
  }

  bool _hasHash(String hash) {
    return _songs.any((Song song) => song.contentHash == hash);
  }

  Artist _artistNamed(String name) {
    if (name == unknownArtistName) {
      return _ensureArtist(unknownArtistId, unknownArtistName);
    }
    for (final Artist artist in _artists) {
      if (artist.name == name) {
        return artist;
      }
    }
    final Artist created = Artist(id: _newId(), name: name);
    _artists = <Artist>[..._artists, created];
    return created;
  }

  Album _albumNamed({
    required String title,
    required String albumArtistId,
  }) {
    if (title == unknownAlbumTitle) {
      return _ensureAlbum(unknownAlbumId, unknownAlbumTitle, unknownArtistId);
    }
    for (final Album album in _albums) {
      if (album.title == title && album.artistId == albumArtistId) {
        return album;
      }
    }
    final Album created = Album(
      id: _newId(),
      title: title,
      artistId: albumArtistId,
    );
    _albums = <Album>[..._albums, created];
    return created;
  }

  Artist _ensureArtist(String id, String name) {
    for (final Artist artist in _artists) {
      if (artist.id == id) {
        return artist;
      }
    }
    final Artist created = Artist(id: id, name: name);
    _artists = <Artist>[..._artists, created];
    return created;
  }

  Album _ensureAlbum(String id, String title, String artistId) {
    for (final Album album in _albums) {
      if (album.id == id) {
        return album;
      }
    }
    final Album created = Album(id: id, title: title, artistId: artistId);
    _albums = <Album>[..._albums, created];
    return created;
  }

  Future<Album> _withCover(Album album, List<int>? bytes) async {
    if (album.coverPath != null) {
      return album;
    }
    if (bytes == null || bytes.isEmpty) {
      return album;
    }
    final String? path = await localDisk.saveCover(
      albumId: album.id,
      bytes: bytes,
      maxSide: coverLongestSide,
    );
    if (path == null) {
      return album;
    }
    final Album updated = album.copyWith(coverPath: path);
    _albums = <Album>[
      for (final Album item in _albums)
        if (item.id == updated.id) updated else item,
    ];
    return updated;
  }

  String _newId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 20)}';
  }

  String? _blankToNull(String? value) {
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  Song _withTitle(Song song, String? title) {
    final String? next = _blankToNull(title);
    if (next == null || next == song.title) {
      return song;
    }
    return song.copyWith(
      title: next,
      syncState: SyncState.dirty,
      updatedAt: DateTime.now(),
    );
  }

  Song _withArtist(Song song, String? artistName) {
    final String? next = _blankToNull(artistName);
    if (next == null) {
      return song;
    }
    final Artist artist = _artistNamed(next);
    if (artist.id == song.artistId) {
      return song;
    }
    return song.copyWith(
      artistId: artist.id,
      syncState: SyncState.dirty,
      updatedAt: DateTime.now(),
    );
  }

  void _renameAlbum(String albumId, String? title) {
    final String? next = _blankToNull(title);
    if (next == null) {
      return;
    }
    _albums = <Album>[
      for (final Album album in _albums)
        if (album.id == albumId && album.title != next)
          album.copyWith(
            title: next,
            syncState: SyncState.dirty,
            updatedAt: DateTime.now(),
          )
        else
          album,
    ];
  }

  void _replaceSong(Song updated) {
    _songs = <Song>[
      for (final Song item in _songs)
        if (item.id == updated.id) updated else item,
    ];
    if (_currentSong?.id == updated.id) {
      _currentSong = updated;
    }
  }

  void _replaceAlbum(Album updated) {
    _albums = <Album>[
      for (final Album item in _albums)
        if (item.id == updated.id) updated else item,
    ];
  }

  Album? _albumById(String id) {
    for (final Album album in _albums) {
      if (album.id == id) {
        return album;
      }
    }
    return null;
  }

  void _markPendingDelete(String songId) {
    _songs = <Song>[
      for (final Song item in _songs)
        if (item.id == songId)
          item.copyWith(
            syncState: SyncState.pendingDelete,
            updatedAt: DateTime.now(),
          )
        else
          item,
    ];
  }

  void _dropQueueId(String songId) {
    final int index = _queueIds.indexOf(songId);
    if (index < 0) {
      return;
    }
    _queueIds.removeAt(index);
    if (index < _queueIndex) {
      _queueIndex -= 1;
    }
    _queueIndex = _clampedIndex(_queueIndex);
  }

  void _dropFavoriteId(String songId) {
    if (!_favorites.songIds.contains(songId)) {
      return;
    }
    _favorites = Favorites(
      songIds: <String>[
        for (final String id in _favorites.songIds)
          if (id != songId) id,
      ],
      updatedAt: DateTime.now(),
    );
  }

  Future<void> _persistLibrary() async {
    await _saveSnapshot(manifestDirty: true);
    await _trySync();
  }

  LibrarySnapshot _librarySnapshot() {
    return LibrarySnapshot(
      songs: List<Song>.of(_songs),
      artists: List<Artist>.of(_artists),
      albums: List<Album>.of(_albums),
      favorites: Favorites(
        songIds: List<String>.of(_favorites.songIds),
        updatedAt: _favorites.updatedAt,
      ),
      manifestFileId: _manifestFileId,
      manifestDirty: _manifestDirty,
      cacheLimitBytes: _cacheLimitBytes,
    );
  }

  Future<void> _saveSnapshot({required bool manifestDirty}) async {
    _manifestDirty = manifestDirty;
    await localDisk.saveLibrary(_librarySnapshot());
  }

  Future<void> _reloadLibrary() async {
    final LibrarySnapshot? stored = await localDisk.loadLibrary();
    if (stored != null) {
      _songs = List<Song>.of(stored.songs);
      _artists = List<Artist>.of(stored.artists);
      _albums = List<Album>.of(stored.albums);
      _favorites = Favorites(
        songIds: List<String>.of(stored.favorites.songIds),
        updatedAt: stored.favorites.updatedAt,
      );
      _manifestFileId = stored.manifestFileId;
      _manifestDirty = stored.manifestDirty;
      _cacheLimitBytes = stored.cacheLimitBytes;
      return;
    }
    await _reloadSongsFromPaths();
    _manifestFileId = null;
    _manifestDirty = _songs.isNotEmpty;
    _cacheLimitBytes = defaultAudioCacheLimitBytes;
  }

  Future<void> _reloadSongsFromPaths() async {
    final List<String> paths = await localDisk.listLibraryPaths();
    _songs = <Song>[
      for (final String path in paths) _songFromPath(path),
    ];
    _artists = _placeholderArtists();
    _albums = _placeholderAlbums();
  }

  List<Artist> _placeholderArtists() {
    if (_songs.isEmpty) {
      return const <Artist>[];
    }
    return <Artist>[
      Artist(id: unknownArtistId, name: unknownArtistName),
    ];
  }

  List<Album> _placeholderAlbums() {
    if (_songs.isEmpty) {
      return const <Album>[];
    }
    return <Album>[
      Album(id: unknownAlbumId, title: unknownAlbumTitle),
    ];
  }

  Song _songFromPath(String path) {
    return Song(
      id: path,
      title: p.basename(path),
      localAudioPath: path,
      artistId: unknownArtistId,
      albumId: unknownAlbumId,
    );
  }

  Future<void> _playAt(int index) async {
    _queueIndex = index;
    final Song? song = _songById(_queueIds[index]);
    if (song == null) {
      return;
    }
    _currentSong = song;
    final bool fillCache =
        !await _hasPlayableAudio(song) && song.audioFileId != null;
    await _setPlaybackSource(song);
    await audioEngine.play();
    await _persistQueue();
    _emitPlayback();
    if (fillCache) {
      await _fillRemoteCache(_songById(song.id) ?? song);
    }
  }

  void _emitPlayback() {
    _playbackChanged.add(null);
  }

  Future<void> _setPlaybackSource(Song song) async {
    if (await _hasFile(song.localAudioPath)) {
      await audioEngine.setLocalSource(song.localAudioPath);
      return;
    }
    if (await _hasFile(song.cachedAudioPath)) {
      await _touchCache(song);
      await audioEngine.setLocalSource(song.cachedAudioPath);
      return;
    }
    await _playRemote(song);
  }

  Future<void> _playRemote(Song song) async {
    final String? fileId = song.audioFileId;
    if (fileId == null) {
      return;
    }
    final String fileToken = await _fileAccessToken(fileId);
    await audioEngine.setRemoteSource(
      url: storeFiles.fileContentUrl(fileId),
      headers: <String, String>{'Authorization': 'Bearer $fileToken'},
    );
  }

  Future<void> _fillRemoteCache(Song song) async {
    final String? fileId = song.audioFileId;
    if (fileId == null) {
      return;
    }
    final String fileToken = await _fileAccessToken(fileId);
    await _writeRemoteCache(song, fileId, fileToken);
  }

  Future<String> _fileAccessToken(String fileId) async {
    await _ensureAccess();
    return storeFiles.issueFileAccessToken(
      accessToken: _requireTokens().accessToken,
      fileId: fileId,
    );
  }

  Future<void> _writeRemoteCache(Song song, String fileId, String fileToken) async {
    final List<int> bytes = await storeFiles.downloadRange(
      fileAccessToken: fileToken,
      fileId: fileId,
    );
    final String path = await localDisk.writeAudioCache(
      songId: song.id,
      extension: _cacheExtension(song),
      bytes: bytes,
    );
    _replaceSong(
      song.copyWith(
        cachedAudioPath: path,
        cachedSizeBytes: bytes.length,
        cacheAccessedAt: _nextCacheAccess(),
      ),
    );
    await _evictOverflow();
    await _persistLocalState();
  }

  Future<void> _touchCache(Song song) async {
    _replaceSong(song.copyWith(cacheAccessedAt: _nextCacheAccess()));
    await _persistLocalState();
  }

  Future<void> _evictOverflow() async {
    final List<Song> victims = <Song>[
      for (final Song song in _songs)
        if (song.cachedAudioPath.isNotEmpty && !song.isPinnedDownload) song,
    ];
    victims.sort(_byCacheAccess);
    for (final Song song in victims) {
      if (cacheUsageBytes <= _cacheLimitBytes) {
        return;
      }
      await _dropCache(song);
    }
  }

  int _byCacheAccess(Song a, Song b) {
    final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final DateTime at = a.cacheAccessedAt ?? epoch;
    final DateTime bt = b.cacheAccessedAt ?? epoch;
    return at.compareTo(bt);
  }

  Future<void> _dropCache(Song song) async {
    if (song.cachedAudioPath.isNotEmpty) {
      await localDisk.deletePath(song.cachedAudioPath);
    }
    _replaceSong(
      song.copyWith(
        cachedAudioPath: '',
        cachedSizeBytes: 0,
      ),
    );
  }

  Future<void> _persistLocalState() {
    return localDisk.saveLibrary(_librarySnapshot());
  }

  Future<bool> _hasPlayableAudio(Song song) async {
    return await _hasFile(song.localAudioPath) ||
        await _hasFile(song.cachedAudioPath);
  }

  Future<bool> _hasFile(String path) async {
    if (path.isEmpty) {
      return false;
    }
    return localDisk.exists(path);
  }

  DateTime _nextCacheAccess() {
    _cacheClock += 1;
    return DateTime.now().add(Duration(microseconds: _cacheClock));
  }

  String _cacheExtension(Song song) {
    final String ext = p.extension(song.localAudioPath);
    if (ext.isNotEmpty) {
      return ext;
    }
    return '.mp3';
  }

  Future<void> _advanceAfterCompleted() async {
    if (audioEngine.repeatMode == RepeatMode.one) {
      await audioEngine.seek(Duration.zero);
      await audioEngine.play();
      return;
    }
    await skipToNext();
  }

  int _nextIndex() {
    final int next = _queueIndex + 1;
    if (next < _queueIds.length) {
      return next;
    }
    return 0;
  }

  int _shuffledIndex() {
    if (_queueIds.length == 1) {
      return 0;
    }
    int next = _random.nextInt(_queueIds.length);
    if (next == _queueIndex) {
      next = (next + 1) % _queueIds.length;
    }
    return next;
  }

  Song? _songById(String id) {
    for (final Song song in _songs) {
      if (song.id == id) {
        return song;
      }
    }
    return null;
  }

  Future<void> _persistQueue() async {
    await localDisk.saveQueue(
      QueueState(
        songIds: List<String>.of(_queueIds),
        currentIndex: _queueIndex,
        position: audioEngine.position,
        repeatMode: audioEngine.repeatMode,
        shuffleEnabled: audioEngine.shuffleEnabled,
      ),
    );
  }

  Future<void> _restoreQueue() async {
    final QueueState? stored = await localDisk.loadQueue();
    if (stored == null) {
      return;
    }
    _queueIds = List<String>.of(stored.songIds);
    _queueIndex = _clampedIndex(stored.currentIndex);
    await audioEngine.setRepeatMode(stored.repeatMode);
    await audioEngine.setShuffleEnabled(stored.shuffleEnabled);
    if (_queueIds.isEmpty) {
      return;
    }
    final Song? song = _songById(_queueIds[_queueIndex]);
    if (song == null) {
      return;
    }
    _currentSong = song;
    await _setPlaybackSource(song);
    await audioEngine.seek(stored.position);
  }

  int _clampedIndex(int index) {
    if (_queueIds.isEmpty) {
      return 0;
    }
    if (index < 0) {
      return 0;
    }
    if (index >= _queueIds.length) {
      return _queueIds.length - 1;
    }
    return index;
  }
}

enum _ImportOutcome { imported, duplicate, ignored }
