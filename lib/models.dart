/// Access Token 默认有效期，单位秒。
const int accessExpiresInSeconds = 900;

/// 缺标签时的占位歌手标识。
const String unknownArtistId = 'unknown-artist';

/// 缺标签时的占位歌手名称。
const String unknownArtistName = '未知歌手';

/// 缺标签时的占位专辑标识。
const String unknownAlbumId = 'unknown-album';

/// 缺标签时的占位专辑名称。
const String unknownAlbumTitle = '未知专辑';

/// Cover 最长边像素。
const int coverLongestSide = 512;

/// 小文件直传字节上限。
const int directUploadMaxBytes = 10485760;

/// 上传至 server 的 Manifest 文件名。
const String manifestFilename = 'library-manifest.json';

/// 音频缓存默认上限，单位字节。
const int defaultAudioCacheLimitBytes = 2147483648;

/// 文件夹扫描与拖拽导入识别的常见音频扩展名。
const Set<String> libraryAudioExtensions = <String>{
  '.mp3',
  '.flac',
  '.m4a',
  '.mp4',
  '.aac',
  '.ogg',
  '.opus',
  '.wav',
  '.wma',
};

bool isLibraryAudioPath(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) {
    return false;
  }
  return libraryAudioExtensions.contains(path.substring(dot).toLowerCase());
}

/// 元数据或资源相对 server 的同步状态。
enum SyncState { synced, dirty, pendingDelete }

final class Song {
  Song({
    required this.id,
    required this.title,
    required this.localAudioPath,
    required this.artistId,
    required this.albumId,
    this.albumArtistId,
    this.trackNumber,
    this.lyrics,
    this.contentHash,
    this.audioFileId,
    this.lyricsFileId,
    this.cachedAudioPath = '',
    this.isPinnedDownload = false,
    this.cachedSizeBytes = 0,
    this.cacheAccessedAt,
    this.syncState = SyncState.dirty,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final String localAudioPath;
  final String artistId;
  final String albumId;
  final String? albumArtistId;
  final int? trackNumber;
  final String? lyrics;
  final String? contentHash;
  final String? audioFileId;
  final String? lyricsFileId;
  final String cachedAudioPath;
  final bool isPinnedDownload;
  final int cachedSizeBytes;
  final DateTime? cacheAccessedAt;
  final SyncState syncState;
  final DateTime updatedAt;

  /// 仅有云端音频、无本机文件也无缓存时需联网。
  bool get needsNetwork {
    return localAudioPath.isEmpty &&
        cachedAudioPath.isEmpty &&
        audioFileId != null;
  }

  Song copyWith({
    String? title,
    String? artistId,
    String? audioFileId,
    String? lyricsFileId,
    String? cachedAudioPath,
    bool? isPinnedDownload,
    int? cachedSizeBytes,
    DateTime? cacheAccessedAt,
    SyncState? syncState,
    DateTime? updatedAt,
  }) {
    return Song(
      id: id,
      title: title ?? this.title,
      localAudioPath: localAudioPath,
      artistId: artistId ?? this.artistId,
      albumId: albumId,
      albumArtistId: albumArtistId,
      trackNumber: trackNumber,
      lyrics: lyrics,
      contentHash: contentHash,
      audioFileId: audioFileId ?? this.audioFileId,
      lyricsFileId: lyricsFileId ?? this.lyricsFileId,
      cachedAudioPath: cachedAudioPath ?? this.cachedAudioPath,
      isPinnedDownload: isPinnedDownload ?? this.isPinnedDownload,
      cachedSizeBytes: cachedSizeBytes ?? this.cachedSizeBytes,
      cacheAccessedAt: cacheAccessedAt ?? this.cacheAccessedAt,
      syncState: syncState ?? this.syncState,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'local_audio_path': localAudioPath,
      'artist_id': artistId,
      'album_id': albumId,
      'album_artist_id': albumArtistId,
      'track_number': trackNumber,
      'lyrics': lyrics,
      'content_hash': contentHash,
      'audio_file_id': audioFileId,
      'lyrics_file_id': lyricsFileId,
      'cached_audio_path': cachedAudioPath,
      'is_pinned_download': isPinnedDownload,
      'cached_size_bytes': cachedSizeBytes,
      if (cacheAccessedAt case final DateTime accessed)
        'cache_accessed_at': accessed.toUtc().toIso8601String(),
      'sync_state': syncState.name,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> toManifestJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'artist_id': artistId,
      'album_id': albumId,
      'album_artist_id': albumArtistId,
      'track_number': trackNumber,
      'lyrics': lyrics,
      'content_hash': contentHash,
      'audio_file_id': audioFileId,
      'lyrics_file_id': lyricsFileId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? title = json['title'];
    final Object? localAudioPath = json['local_audio_path'];
    final Object? artistId = json['artist_id'];
    final Object? albumId = json['album_id'];
    if (id is! String ||
        title is! String ||
        artistId is! String ||
        albumId is! String) {
      throw const FormatException('Song 字段缺失');
    }
    final Object? albumArtistId = json['album_artist_id'];
    final Object? trackNumber = json['track_number'];
    final Object? lyrics = json['lyrics'];
    final Object? contentHash = json['content_hash'];
    final Object? audioFileId = json['audio_file_id'];
    final Object? lyricsFileId = json['lyrics_file_id'];
    final Object? cachedAudioPath = json['cached_audio_path'];
    final Object? cachedSizeBytes = json['cached_size_bytes'];
    final Object? cacheAccessedAt = json['cache_accessed_at'];
    return Song(
      id: id,
      title: title,
      localAudioPath: localAudioPath is String ? localAudioPath : '',
      artistId: artistId,
      albumId: albumId,
      albumArtistId: albumArtistId is String ? albumArtistId : null,
      trackNumber: trackNumber is int ? trackNumber : null,
      lyrics: lyrics is String ? lyrics : null,
      contentHash: contentHash is String ? contentHash : null,
      audioFileId: audioFileId is String ? audioFileId : null,
      lyricsFileId: lyricsFileId is String ? lyricsFileId : null,
      cachedAudioPath: cachedAudioPath is String ? cachedAudioPath : '',
      isPinnedDownload: json['is_pinned_download'] == true,
      cachedSizeBytes: cachedSizeBytes is int ? cachedSizeBytes : 0,
      cacheAccessedAt: cacheAccessedAt is String
          ? DateTime.parse(cacheAccessedAt)
          : null,
      syncState: _syncStateFromJson(json['sync_state']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

final class Artist {
  Artist({
    required this.id,
    required this.name,
    this.syncState = SyncState.dirty,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String name;
  final SyncState syncState;
  final DateTime updatedAt;

  Artist copyWith({
    String? name,
    SyncState? syncState,
    DateTime? updatedAt,
  }) {
    return Artist(
      id: id,
      name: name ?? this.name,
      syncState: syncState ?? this.syncState,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object> toJson() {
    return <String, Object>{
      'id': id,
      'name': name,
      'sync_state': syncState.name,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object> toManifestJson() => toJson();

  factory Artist.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? name = json['name'];
    if (id is! String || name is! String) {
      throw const FormatException('Artist 字段缺失');
    }
    return Artist(
      id: id,
      name: name,
      syncState: _syncStateFromJson(json['sync_state']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

final class Album {
  Album({
    required this.id,
    required this.title,
    this.artistId,
    this.coverPath,
    this.coverFileId,
    this.syncState = SyncState.dirty,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final String? artistId;
  final String? coverPath;
  final String? coverFileId;
  final SyncState syncState;
  final DateTime updatedAt;

  Album copyWith({
    String? title,
    String? coverPath,
    String? coverFileId,
    SyncState? syncState,
    DateTime? updatedAt,
  }) {
    return Album(
      id: id,
      title: title ?? this.title,
      artistId: artistId,
      coverPath: coverPath ?? this.coverPath,
      coverFileId: coverFileId ?? this.coverFileId,
      syncState: syncState ?? this.syncState,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'artist_id': artistId,
      'cover_path': coverPath,
      'cover_file_id': coverFileId,
      'sync_state': syncState.name,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> toManifestJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'artist_id': artistId,
      'cover_file_id': coverFileId,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'sync_state': syncState.name,
    };
  }

  factory Album.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? title = json['title'];
    if (id is! String || title is! String) {
      throw const FormatException('Album 字段缺失');
    }
    final Object? artistId = json['artist_id'];
    final Object? coverPath = json['cover_path'];
    final Object? coverFileId = json['cover_file_id'];
    return Album(
      id: id,
      title: title,
      artistId: artistId is String ? artistId : null,
      coverPath: coverPath is String ? coverPath : null,
      coverFileId: coverFileId is String ? coverFileId : null,
      syncState: _syncStateFromJson(json['sync_state']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

/// ID3 与 Vorbis 读出的标签。
final class AudioTags {
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.lyrics,
    this.coverBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final String? lyrics;
  final List<int>? coverBytes;
}

/// 一次导入的新增与去重计数。
final class ImportResult {
  const ImportResult({
    this.importedCount = 0,
    this.duplicateCount = 0,
  });

  final int importedCount;
  final int duplicateCount;
}

/// 用户唯一的收藏列表。有序 Song id，带 updatedAt，供后续写入 Manifest。
final class Favorites {
  Favorites({
    this.songIds = const <String>[],
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final List<String> songIds;
  final DateTime updatedAt;

  Map<String, Object> toJson() {
    return <String, Object>{
      'song_ids': songIds,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory Favorites.fromJson(Map<String, dynamic> json) {
    final Object? ids = json['song_ids'];
    return Favorites(
      songIds: ids is List
          ? <String>[
              for (final Object? id in ids)
                if (id is String) id,
            ]
          : const <String>[],
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }
}

/// 本机曲库 Artist、Album、Song 与 Favorites 快照。
final class LibrarySnapshot {
  LibrarySnapshot({
    this.songs = const <Song>[],
    this.artists = const <Artist>[],
    this.albums = const <Album>[],
    Favorites? favorites,
    this.manifestFileId,
    this.manifestDirty = false,
    this.cacheLimitBytes = defaultAudioCacheLimitBytes,
  }) : favorites = favorites ?? Favorites();

  final List<Song> songs;
  final List<Artist> artists;
  final List<Album> albums;
  final Favorites favorites;
  final String? manifestFileId;
  final bool manifestDirty;
  final int cacheLimitBytes;

  Map<String, Object> toJson() {
    return <String, Object>{
      'songs': <Map<String, Object?>>[
        for (final Song song in songs) song.toJson(),
      ],
      'artists': <Map<String, Object>>[
        for (final Artist artist in artists) artist.toJson(),
      ],
      'albums': <Map<String, Object?>>[
        for (final Album album in albums) album.toJson(),
      ],
      'favorites': favorites.toJson(),
      'manifest_dirty': manifestDirty,
      'cache_limit_bytes': cacheLimitBytes,
      if (manifestFileId case final String id) 'manifest_file_id': id,
    };
  }

  Map<String, Object> toManifestJson() {
    return <String, Object>{
      'artists': <Map<String, Object?>>[
        for (final Artist artist in artists) artist.toManifestJson(),
      ],
      'albums': <Map<String, Object?>>[
        for (final Album album in albums) album.toManifestJson(),
      ],
      'songs': <Map<String, Object?>>[
        for (final Song song in songs) song.toManifestJson(),
      ],
      'favorites': favorites.toJson(),
    };
  }

  factory LibrarySnapshot.fromJson(Map<String, dynamic> json) {
    final Object? manifestId = json['manifest_file_id'];
    final Object? dirty = json['manifest_dirty'];
    final Object? cacheLimit = json['cache_limit_bytes'];
    return LibrarySnapshot(
      songs: _songList(json['songs']),
      artists: _artistList(json['artists']),
      albums: _albumList(json['albums']),
      favorites: _favoritesFrom(json['favorites']),
      manifestFileId: manifestId is String ? manifestId : null,
      manifestDirty: dirty is bool ? dirty : manifestId is! String,
      cacheLimitBytes:
          cacheLimit is int ? cacheLimit : defaultAudioCacheLimitBytes,
    );
  }
}

/// store/server 文件元数据。
final class StoreFile {
  const StoreFile({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
  });

  final String id;
  final String filename;
  final String contentType;
  final int sizeBytes;

  factory StoreFile.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? filename = json['filename'];
    final Object? contentType = json['content_type'];
    final Object? sizeBytes = json['size_bytes'];
    if (id is! String ||
        filename is! String ||
        contentType is! String ||
        sizeBytes is! int) {
      throw const FormatException('文件元数据字段缺失');
    }
    return StoreFile(
      id: id,
      filename: filename,
      contentType: contentType,
      sizeBytes: sizeBytes,
    );
  }
}

List<Song> _songList(Object? value) {
  if (value is! List) {
    return const <Song>[];
  }
  return <Song>[
    for (final Object? item in value)
      if (item is Map<String, dynamic>) Song.fromJson(item),
  ];
}

List<Artist> _artistList(Object? value) {
  if (value is! List) {
    return const <Artist>[];
  }
  return <Artist>[
    for (final Object? item in value)
      if (item is Map<String, dynamic>) Artist.fromJson(item),
  ];
}

List<Album> _albumList(Object? value) {
  if (value is! List) {
    return const <Album>[];
  }
  return <Album>[
    for (final Object? item in value)
      if (item is Map<String, dynamic>) Album.fromJson(item),
  ];
}

Favorites _favoritesFrom(Object? value) {
  if (value is Map<String, dynamic>) {
    return Favorites.fromJson(value);
  }
  return Favorites();
}

/// AudioEngine 的循环模式。
enum RepeatMode { one, all }

/// 本机持久化的 Queue 与播放游标。
final class QueueState {
  const QueueState({
    required this.songIds,
    this.currentIndex = 0,
    this.position = Duration.zero,
    this.repeatMode = RepeatMode.all,
    this.shuffleEnabled = false,
  });

  final List<String> songIds;
  final int currentIndex;
  final Duration position;
  final RepeatMode repeatMode;
  final bool shuffleEnabled;

  Map<String, Object> toJson() {
    return <String, Object>{
      'song_ids': songIds,
      'current_index': currentIndex,
      'position_ms': position.inMilliseconds,
      'repeat_mode': repeatMode.name,
      'shuffle_enabled': shuffleEnabled,
    };
  }

  factory QueueState.fromJson(Map<String, dynamic> json) {
    final Object? ids = json['song_ids'];
    final Object? index = json['current_index'];
    if (ids is! List || index is! int) {
      throw const FormatException('Queue 字段缺失');
    }
    final Object? positionMs = json['position_ms'];
    return QueueState(
      songIds: <String>[
        for (final Object? id in ids)
          if (id is String) id,
      ],
      currentIndex: index,
      position: Duration(milliseconds: positionMs is int ? positionMs : 0),
      repeatMode: _repeatModeNamed(json['repeat_mode']),
      shuffleEnabled: json['shuffle_enabled'] == true,
    );
  }
}

RepeatMode _repeatModeNamed(Object? value) {
  if (value == RepeatMode.one.name) {
    return RepeatMode.one;
  }
  return RepeatMode.all;
}

SyncState _syncStateFromJson(Object? value) {
  for (final SyncState state in SyncState.values) {
    if (state.name == value) {
      return state;
    }
  }
  return SyncState.dirty;
}

DateTime _dateTimeFromJson(Object? value) {
  if (value is String) {
    return DateTime.parse(value);
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

final class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
  });

  final String id;
  final String username;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? username = json['username'];
    if (id is! String || username is! String) {
      throw const FormatException('用户信息字段缺失');
    }
    return AuthUser(id: id, username: username);
  }
}

final class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Map<String, String> toJson() {
    return <String, String>{
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt.toUtc().toIso8601String(),
    };
  }

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    final Object? accessToken = json['access_token'];
    final Object? refreshToken = json['refresh_token'];
    final Object? expiresAt = json['expires_at'];
    if (accessToken is! String || refreshToken is! String || expiresAt is! String) {
      throw const FormatException('凭证字段缺失');
    }
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.parse(expiresAt),
    );
  }

  factory AuthTokens.fromApi(
    Map<String, dynamic> json, {
    String? fallbackRefresh,
  }) {
    final Object? accessToken = json['access_token'];
    if (accessToken is! String) {
      throw const FormatException('缺少 access_token');
    }
    final Object? refreshValue = json['refresh_token'];
    final String refreshToken;
    if (refreshValue is String) {
      refreshToken = refreshValue;
    } else if (fallbackRefresh != null) {
      refreshToken = fallbackRefresh;
    } else {
      throw const FormatException('缺少 refresh_token');
    }
    final Object? expiresValue = json['expires_in'];
    final int expiresIn =
        expiresValue is int ? expiresValue : accessExpiresInSeconds;
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }
}

final class AuthException implements Exception {
  const AuthException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}
