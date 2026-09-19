import 'package:music_app/models.dart';

/// 将远端 Manifest 与本机曲库按实体 updatedAt 做 last-write-wins 合并。
/// pendingDelete 的时间戳不早于对方时胜过编辑。Favorites 整表比较 updatedAt。
LibrarySnapshot mergeLibrary(LibrarySnapshot local, LibrarySnapshot remote) {
  return LibrarySnapshot(
    songs: mergeSongs(local.songs, remote.songs),
    artists: mergeArtists(local.artists, remote.artists),
    albums: mergeAlbums(local.albums, remote.albums),
    favorites: mergeFavorites(local.favorites, remote.favorites),
  );
}

List<Song> mergeSongs(List<Song> local, List<Song> remote) {
  return _mergeKeyed(
    local: local,
    remote: remote,
    idOf: (Song song) => song.id,
    merge: mergeSong,
  );
}

List<Artist> mergeArtists(List<Artist> local, List<Artist> remote) {
  return _mergeKeyed(
    local: local,
    remote: remote,
    idOf: (Artist artist) => artist.id,
    merge: mergeArtist,
  );
}

List<Album> mergeAlbums(List<Album> local, List<Album> remote) {
  return _mergeKeyed(
    local: local,
    remote: remote,
    idOf: (Album album) => album.id,
    merge: mergeAlbum,
  );
}

Favorites mergeFavorites(Favorites local, Favorites remote) {
  if (!_isBefore(local.updatedAt, remote.updatedAt)) {
    return _copyFavorites(local);
  }
  return _copyFavorites(remote);
}

Song mergeSong(Song local, Song remote) {
  final Song winner = _lastWriteWins(
    local: local,
    remote: remote,
    localState: local.syncState,
    remoteState: remote.syncState,
    localAt: local.updatedAt,
    remoteAt: remote.updatedAt,
  );
  final Song other = identical(winner, local) ? remote : local;
  return Song(
    id: winner.id,
    title: winner.title,
    localAudioPath: _preferPath(winner.localAudioPath, other.localAudioPath),
    artistId: winner.artistId,
    albumId: winner.albumId,
    albumArtistId: winner.albumArtistId,
    trackNumber: winner.trackNumber,
    lyrics: winner.lyrics,
    contentHash: winner.contentHash ?? other.contentHash,
    audioFileId: winner.audioFileId ?? other.audioFileId,
    lyricsFileId: winner.lyricsFileId ?? other.lyricsFileId,
    cachedAudioPath: _preferPath(local.cachedAudioPath, remote.cachedAudioPath),
    isPinnedDownload: local.isPinnedDownload || remote.isPinnedDownload,
    cachedSizeBytes:
        local.cachedSizeBytes != 0 ? local.cachedSizeBytes : remote.cachedSizeBytes,
    cacheAccessedAt: local.cacheAccessedAt ?? remote.cacheAccessedAt,
    syncState: winner.syncState,
    updatedAt: winner.updatedAt,
  );
}

Artist mergeArtist(Artist local, Artist remote) {
  return _lastWriteWins(
    local: local,
    remote: remote,
    localState: local.syncState,
    remoteState: remote.syncState,
    localAt: local.updatedAt,
    remoteAt: remote.updatedAt,
  );
}

Album mergeAlbum(Album local, Album remote) {
  final Album winner = _lastWriteWins(
    local: local,
    remote: remote,
    localState: local.syncState,
    remoteState: remote.syncState,
    localAt: local.updatedAt,
    remoteAt: remote.updatedAt,
  );
  final Album other = identical(winner, local) ? remote : local;
  return Album(
    id: winner.id,
    title: winner.title,
    artistId: winner.artistId,
    coverPath: winner.coverPath ?? other.coverPath,
    coverFileId: winner.coverFileId ?? other.coverFileId,
    syncState: winner.syncState,
    updatedAt: winner.updatedAt,
  );
}

List<T> _mergeKeyed<T>({
  required List<T> local,
  required List<T> remote,
  required String Function(T value) idOf,
  required T Function(T local, T remote) merge,
}) {
  final Map<String, T> localById = <String, T>{
    for (final T item in local) idOf(item): item,
  };
  final Map<String, T> remoteById = <String, T>{
    for (final T item in remote) idOf(item): item,
  };
  final Set<String> ids = <String>{...localById.keys, ...remoteById.keys};
  return <T>[
    for (final String id in ids) _pick(localById[id], remoteById[id], merge),
  ];
}

T _pick<T>(T? local, T? remote, T Function(T local, T remote) merge) {
  if (local == null) {
    return remote!;
  }
  if (remote == null) {
    return local;
  }
  return merge(local, remote);
}

T _lastWriteWins<T>({
  required T local,
  required T remote,
  required SyncState localState,
  required SyncState remoteState,
  required DateTime localAt,
  required DateTime remoteAt,
}) {
  if (_pendingDeleteWins(localState, localAt, remoteAt)) {
    return local;
  }
  if (_pendingDeleteWins(remoteState, remoteAt, localAt)) {
    return remote;
  }
  if (_isAfter(localAt, remoteAt)) {
    return local;
  }
  if (_isAfter(remoteAt, localAt)) {
    return remote;
  }
  return local;
}

bool _pendingDeleteWins(SyncState state, DateTime at, DateTime otherAt) {
  return state == SyncState.pendingDelete && !_isBefore(at, otherAt);
}

bool _isBefore(DateTime a, DateTime b) => a.toUtc().isBefore(b.toUtc());

bool _isAfter(DateTime a, DateTime b) => a.toUtc().isAfter(b.toUtc());

String _preferPath(String primary, String fallback) {
  return primary.isEmpty ? fallback : primary;
}

Favorites _copyFavorites(Favorites favorites) {
  return Favorites(
    songIds: List<String>.of(favorites.songIds),
    updatedAt: favorites.updatedAt,
  );
}
