import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/merge_library.dart';
import 'package:music_app/models.dart';

LibrarySession _session(FakeStoreFiles storeFiles, FakeLocalDisk localDisk) {
  return LibrarySession(
    storeFiles: storeFiles,
    localDisk: localDisk,
    audioEngine: FakeAudioEngine(),
  );
}

Song _song({
  required String id,
  required String title,
  required DateTime updatedAt,
  String localAudioPath = '',
  String artistId = 'ar',
  String albumId = 'al',
  SyncState syncState = SyncState.synced,
  String? audioFileId,
  String? lyricsFileId,
  String? contentHash,
}) {
  return Song(
    id: id,
    title: title,
    localAudioPath: localAudioPath,
    artistId: artistId,
    albumId: albumId,
    audioFileId: audioFileId,
    lyricsFileId: lyricsFileId,
    contentHash: contentHash,
    syncState: syncState,
    updatedAt: updatedAt,
  );
}

Artist _artist({
  required String id,
  required String name,
  required DateTime updatedAt,
  SyncState syncState = SyncState.synced,
}) {
  return Artist(id: id, name: name, syncState: syncState, updatedAt: updatedAt);
}

Album _album({
  required String id,
  required String title,
  required DateTime updatedAt,
  String? coverPath,
  String? coverFileId,
  SyncState syncState = SyncState.synced,
}) {
  return Album(
    id: id,
    title: title,
    coverPath: coverPath,
    coverFileId: coverFileId,
    syncState: syncState,
    updatedAt: updatedAt,
  );
}

LibrarySnapshot _graph({
  required DateTime at,
  required String songId,
  required String title,
  String localAudioPath = '',
  List<String> favoriteIds = const <String>[],
  DateTime? favoritesAt,
  SyncState songState = SyncState.synced,
}) {
  return LibrarySnapshot(
    songs: <Song>[_song(id: songId, title: title, updatedAt: at, localAudioPath: localAudioPath, syncState: songState)],
    artists: <Artist>[_artist(id: 'ar', name: 'Radiohead', updatedAt: at)],
    albums: <Album>[_album(id: 'al', title: 'OK Computer', updatedAt: at)],
    favorites: Favorites(
      songIds: favoriteIds,
      updatedAt: favoritesAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
  );
}

Future<void> _seedManifest(
  FakeStoreFiles storeFiles, {
  required AuthTokens tokens,
  required LibrarySnapshot snapshot,
}) {
  return storeFiles.uploadFile(
    accessToken: tokens.accessToken,
    filename: manifestFilename,
    contentType: 'application/json',
    bytes: utf8.encode(jsonEncode(snapshot.toManifestJson())),
  );
}

void main() {
  final DateTime early = DateTime.utc(2026, 9, 1);
  final DateTime late = DateTime.utc(2026, 9, 2);

  test('实体较新的 updatedAt 胜过较旧编辑', () {
    final LibrarySnapshot merged = mergeLibrary(
      _graph(at: early, songId: 's1', title: '旧标题', localAudioPath: '/library/a.mp3'),
      _graph(at: late, songId: 's1', title: '新标题'),
    );

    expect(merged.songs.single.title, '新标题');
    expect(merged.songs.single.localAudioPath, '/library/a.mp3');
    expect(merged.artists.single.name, 'Radiohead');
  });

  test('pendingDelete 时间戳不早于对方时胜过编辑', () {
    final LibrarySnapshot merged = mergeLibrary(
      LibrarySnapshot(
        songs: <Song>[
          _song(id: 's1', title: '编辑', updatedAt: late, syncState: SyncState.dirty),
        ],
      ),
      LibrarySnapshot(
        songs: <Song>[
          _song(
            id: 's1',
            title: '已删',
            updatedAt: late,
            syncState: SyncState.pendingDelete,
          ),
        ],
      ),
    );

    expect(merged.songs.single.syncState, SyncState.pendingDelete);
    expect(merged.songs.single.title, '已删');
  });

  test('较早的 pendingDelete 负于较晚的编辑', () {
    final LibrarySnapshot merged = mergeLibrary(
      LibrarySnapshot(
        songs: <Song>[
          _song(
            id: 's1',
            title: '已删',
            updatedAt: early,
            syncState: SyncState.pendingDelete,
          ),
        ],
      ),
      LibrarySnapshot(
        songs: <Song>[
          _song(id: 's1', title: '复活', updatedAt: late, syncState: SyncState.dirty),
        ],
      ),
    );

    expect(merged.songs.single.syncState, SyncState.dirty);
    expect(merged.songs.single.title, '复活');
  });

  test('Favorites 整表按 updatedAt LWW，不按 Song id 逐条合并', () {
    final LibrarySnapshot merged = mergeLibrary(
      LibrarySnapshot(
        favorites: Favorites(songIds: const <String>['a'], updatedAt: early),
      ),
      LibrarySnapshot(
        favorites: Favorites(songIds: const <String>['b', 'c'], updatedAt: late),
      ),
    );

    expect(merged.favorites.songIds, <String>['b', 'c']);
    expect(merged.favorites.updatedAt.isAtSameMomentAs(late), isTrue);
  });

  test('仅一侧存在的实体进入合并结果', () {
    final LibrarySnapshot merged = mergeLibrary(
      LibrarySnapshot(songs: <Song>[_song(id: 'local', title: '本机', updatedAt: early)]),
      LibrarySnapshot(songs: <Song>[_song(id: 'remote', title: '远端', updatedAt: late)]),
    );

    expect(
      merged.songs.map((Song song) => song.id).toSet(),
      <String>{'local', 'remote'},
    );
  });

  test('远端 items 为空时新设备曲库为空', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final LibrarySession session = _session(storeFiles, FakeLocalDisk());

    await session.login(username: 'alice', password: 'password1');

    expect(session.library.songs, isEmpty);
    expect(session.library.artists, isEmpty);
    expect(session.library.albums, isEmpty);
    expect(session.manifestFileId, isNull);
    expect(session.syncError, isNull);
  });

  test('远端 items 为空时本机 dirty 仍上传', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.importFile('/music/a.mp3');
    expect(storeFiles.uploads, isEmpty);

    await session.login(username: 'alice', password: 'password1');

    expect(session.library.songs, isNotEmpty);
    expect(session.syncError, isNull);
    expect(
      storeFiles.uploads.where((FakeUploadedFile file) => file.filename == manifestFilename),
      isNotEmpty,
    );
    expect(session.library.songs.single.audioFileId, isNotNull);
  });

  test('Manifest 不是 JSON 对象时本机曲库保持且不上传', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.importFile('/music/a.mp3');
    await session.addToFavorites(session.library.songs.single);
    final String songId = session.library.songs.single.id;
    final List<String> favoriteIds = session.favorites.songIds;
    final AuthTokens tokens = await storeFiles.login(
      username: 'alice',
      password: 'password1',
    );
    await storeFiles.uploadFile(
      accessToken: tokens.accessToken,
      filename: manifestFilename,
      contentType: 'application/json',
      bytes: utf8.encode('[]'),
    );
    final int manifests = storeFiles.uploads
        .where((FakeUploadedFile file) => file.filename == manifestFilename)
        .length;

    await session.login(username: 'alice', password: 'password1');

    expect(session.library.songs.single.id, songId);
    expect(session.library.artists, isNotEmpty);
    expect(session.library.albums, isNotEmpty);
    expect(session.favorites.songIds, favoriteIds);
    expect(session.syncError, isNotNull);
    expect(
      storeFiles.uploads.where((FakeUploadedFile file) => file.filename == manifestFilename).length,
      manifests,
    );

    final LibrarySession restored = _session(storeFiles, localDisk);
    await restored.restoreSession();

    expect(restored.library.songs.single.id, songId);
    expect(restored.library.artists, isNotEmpty);
    expect(restored.library.albums, isNotEmpty);
    expect(restored.favorites.songIds, favoriteIds);
    expect(restored.syncError, isNotNull);
    expect(
      storeFiles.uploads.where((FakeUploadedFile file) => file.filename == manifestFilename).length,
      manifests,
    );
  });

  test('listFiles 抛错时本机 Song 与 Favorites 保持且不上传 Manifest', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.importFile('/music/a.mp3');
    await session.addToFavorites(session.library.songs.single);
    final String songId = session.library.songs.single.id;
    final List<String> favoriteIds = session.favorites.songIds;
    storeFiles.failListFiles = true;

    await session.login(username: 'alice', password: 'password1');

    expect(session.library.songs.single.id, songId);
    expect(session.library.artists, isNotEmpty);
    expect(session.library.albums, isNotEmpty);
    expect(session.favorites.songIds, favoriteIds);
    expect(
      storeFiles.uploads.where((FakeUploadedFile file) => file.filename == manifestFilename),
      isEmpty,
    );
  });

  test('登录成功但发现失败时会话保持且失败可观察', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles()..failListFiles = true;
    final LibrarySession session = _session(storeFiles, FakeLocalDisk());

    await session.login(username: 'alice', password: 'password1');

    expect(session.currentUser?.username, 'alice');
    expect(session.syncError, isNotNull);
  });

  test('restoreSession 遇到发现失败时保留凭证与曲库', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession first = _session(storeFiles, localDisk);
    await first.login(username: 'alice', password: 'password1');
    await first.importFile('/music/a.mp3');
    await first.addToFavorites(first.library.songs.single);
    final String songId = first.library.songs.single.id;
    final List<String> favoriteIds = first.favorites.songIds;
    final int manifests = storeFiles.uploads
        .where((FakeUploadedFile file) => file.filename == manifestFilename)
        .length;
    storeFiles.failListFiles = true;

    final LibrarySession restored = _session(storeFiles, localDisk);
    await restored.restoreSession();

    expect(restored.currentUser?.username, 'alice');
    expect(localDisk.storedTokens, isNotNull);
    expect(restored.library.songs.single.id, songId);
    expect(restored.favorites.songIds, favoriteIds);
    expect(restored.syncError, isNotNull);
    expect(
      storeFiles.uploads.where((FakeUploadedFile file) => file.filename == manifestFilename).length,
      manifests,
    );
  });

  test('发现最新一份 library-manifest.json 并物化曲库', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final AuthTokens tokens = await storeFiles.login(
      username: 'alice',
      password: 'password1',
    );
    await _seedManifest(
      storeFiles,
      tokens: tokens,
      snapshot: _graph(at: early, songId: 'old', title: '旧库'),
    );
    await _seedManifest(
      storeFiles,
      tokens: tokens,
      snapshot: _graph(at: late, songId: 'new', title: '新库', favoriteIds: <String>['new'], favoritesAt: late),
    );

    final LibrarySession session = _session(storeFiles, FakeLocalDisk());
    await session.login(username: 'alice', password: 'password1');

    expect(session.library.songs.single.id, 'new');
    expect(session.library.songs.single.title, '新库');
    expect(session.library.artists.single.name, 'Radiohead');
    expect(session.library.albums.single.title, 'OK Computer');
    expect(session.favorites.songIds, <String>['new']);
    expect(session.manifestFileId, storeFiles.uploads.last.id);
  });

  test('先拉远端再与本机 LWW，本机较新标题保留且 Queue 不随 Manifest 变化', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk diskA = FakeLocalDisk();
    diskA.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    diskA.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Airbag',
      artist: 'Radiohead',
      album: 'OK Computer',
    );
    final LibrarySession deviceA = _session(storeFiles, diskA);
    await deviceA.login(username: 'alice', password: 'password1');
    await deviceA.importFile('/music/a.mp3');
    await deviceA.playFromView(deviceA.library.songs, deviceA.library.songs.single);
    final List<String> queueA = deviceA.queue;
    final String songId = deviceA.library.songs.single.id;
    final String localPath = deviceA.library.songs.single.localAudioPath;

    final FakeLocalDisk diskB = FakeLocalDisk();
    final LibrarySession deviceB = _session(storeFiles, diskB);
    await deviceB.login(username: 'alice', password: 'password1');
    expect(deviceB.library.songs.single.id, songId);
    expect(deviceB.queue, isEmpty);

    await deviceB.editSong(deviceB.library.songs.single, title: 'B 标题');

    final LibrarySession restoredA = _session(storeFiles, diskA);
    await restoredA.restoreSession();

    expect(restoredA.library.songs.single.title, 'B 标题');
    expect(restoredA.library.songs.single.localAudioPath, localPath);
    expect(restoredA.queue, queueA);
  });

  test('同步 pendingDelete 时删除对应音频、歌词，无剩余 Song 时删除 Cover', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      album: 'OK Computer',
      albumArtist: 'Radiohead',
      coverBytes: <int>[255, 216, 255],
    );
    localDisk.sidecarLyrics['/music/a.mp3'] = '[00:01.00]lyrics';
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');
    await session.importFile('/music/a.mp3');

    final Song song = session.library.songs.single;
    final String? audioId = song.audioFileId;
    final String? lyricsId = song.lyricsFileId;
    final String? coverId = session.library.albumOf(song).coverFileId;
    expect(audioId, isNotNull);
    expect(lyricsId, isNotNull);
    expect(coverId, isNotNull);

    await session.deleteSong(song);

    expect(session.library.songs, isEmpty);
    expect(session.songSyncState(song.id), SyncState.pendingDelete);
    expect(storeFiles.deletedFileIds, containsAll(<String>[audioId!, lyricsId!, coverId!]));
  });

  test('专辑仍有 Song 时不同步删除 Cover', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    localDisk.fileBytes['/music/b.mp3'] = Uint8List.fromList(<int>[4, 5, 6]);
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Airbag',
      artist: 'Radiohead',
      album: 'OK Computer',
      coverBytes: <int>[255, 216, 255],
    );
    localDisk.tagsByPath['/music/b.mp3'] = const AudioTags(
      title: 'Paranoid Android',
      artist: 'Radiohead',
      album: 'OK Computer',
    );
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');
    await session.importFile('/music/a.mp3');
    await session.importFile('/music/b.mp3');

    final Song first = session.library.songs.first;
    final String? coverId = session.library.albumOf(first).coverFileId;
    final String? audioId = first.audioFileId;
    expect(coverId, isNotNull);

    await session.deleteSong(first);

    expect(storeFiles.deletedFileIds, contains(audioId));
    expect(storeFiles.deletedFileIds, isNot(contains(coverId)));
    expect(session.library.albums.single.coverFileId, coverId);
  });

  test('对端 pendingDelete 合并后本机列表为空且 Queue 去掉该 Song', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk diskA = FakeLocalDisk();
    diskA.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession deviceA = _session(storeFiles, diskA);
    await deviceA.login(username: 'alice', password: 'password1');
    await deviceA.importFile('/music/a.mp3');
    final Song song = deviceA.library.songs.single;

    final FakeLocalDisk diskB = FakeLocalDisk();
    final LibrarySession deviceB = _session(storeFiles, diskB);
    await deviceB.login(username: 'alice', password: 'password1');
    await deviceB.playFromView(deviceB.library.songs, deviceB.library.songs.single);
    expect(deviceB.queue, <String>[song.id]);

    await deviceA.deleteSong(song);

    final LibrarySession restoredB = _session(storeFiles, diskB);
    await restoredB.restoreSession();

    expect(restoredB.library.songs, isEmpty);
    expect(restoredB.songSyncState(song.id), SyncState.pendingDelete);
    expect(restoredB.queue, isEmpty);
  });
}
