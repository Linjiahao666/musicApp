import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

LibrarySession _session(FakeStoreFiles storeFiles, FakeLocalDisk localDisk) {
  return LibrarySession(
    storeFiles: storeFiles,
    localDisk: localDisk,
    audioEngine: FakeAudioEngine(),
  );
}

List<FakeUploadedFile> _named(
  FakeStoreFiles storeFiles,
  bool Function(FakeUploadedFile file) match,
) {
  return storeFiles.uploads.where(match).toList();
}

Map<String, dynamic> _manifestJson(FakeStoreFiles storeFiles) {
  final FakeUploadedFile file = _named(
    storeFiles,
    (FakeUploadedFile file) => file.filename == manifestFilename,
  ).last;
  return jsonDecode(utf8.decode(file.bytes)) as Map<String, dynamic>;
}

void main() {
  test('未登录时不同步，不上传文件', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);

    await session.importFile('/music/a.mp3');
    await session.sync();

    expect(storeFiles.uploads, isEmpty);
    expect(session.manifestFileId, isNull);
  });

  test('不超过直传上限的音频走直传，filename 为 songId 加扩展名', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List(directUploadMaxBytes);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');

    await session.importFile('/music/a.mp3');

    final Song song = session.library.songs.single;
    final FakeUploadedFile audio = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename.endsWith('.mp3'),
    ).single;
    expect(audio.filename, '${song.id}.mp3');
    expect(audio.contentType, 'audio/mpeg');
    expect(audio.multipart, isFalse);
    expect(audio.bytes.length, directUploadMaxBytes);
    expect(song.audioFileId, audio.id);
  });

  test('超过直传上限的音频走分片上传', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List(directUploadMaxBytes + 1);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');

    await session.importFile('/music/a.mp3');

    final FakeUploadedFile audio = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename.endsWith('.mp3'),
    ).single;
    expect(audio.multipart, isTrue);
    expect(audio.bytes.length, directUploadMaxBytes + 1);
  });

  test('Cover 与歌词 sidecar 按 albumId 与 songId 命名上传', () async {
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

    final LibraryProjection library = session.library;
    final Song song = library.songs.single;
    final Album album = library.albumOf(song);
    final FakeUploadedFile cover = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename.endsWith('.jpg'),
    ).single;
    final FakeUploadedFile lyrics = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename.endsWith('.lrc'),
    ).single;
    expect(cover.filename, '${album.id}.jpg');
    expect(cover.contentType, 'image/jpeg');
    expect(lyrics.filename, '${song.id}.lrc');
    expect(lyrics.contentType, 'text/plain');
    expect(utf8.decode(lyrics.bytes), '[00:01.00]lyrics');
    expect(song.lyricsFileId, lyrics.id);
    expect(album.coverFileId, cover.id);
  });

  test('仅上传 dirty 资源，已同步音频不再上传', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');
    await session.importFile('/music/a.mp3');
    expect(
      _named(
        storeFiles,
        (FakeUploadedFile file) => file.filename.endsWith('.mp3'),
      ),
      hasLength(1),
    );

    await session.editSong(session.library.songs.single, title: 'New Title');

    expect(
      _named(
        storeFiles,
        (FakeUploadedFile file) => file.filename.endsWith('.mp3'),
      ),
      hasLength(1),
    );
    expect(
      _named(
        storeFiles,
        (FakeUploadedFile file) => file.filename == manifestFilename,
      ),
      hasLength(2),
    );
    expect(session.songSyncState(session.library.songs.single.id), SyncState.synced);
  });

  test('Manifest JSON 含 Artist Album Song Favorites 的 file_id 与 updatedAt', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Airbag',
      artist: 'Radiohead',
      album: 'OK Computer',
    );
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');
    await session.importFile('/music/a.mp3');
    await session.addToFavorites(session.library.songs.single);

    final Map<String, dynamic> json = _manifestJson(storeFiles);
    expect(json.keys, containsAll(<String>['artists', 'albums', 'songs', 'favorites']));
    final Object? songs = json['songs'];
    final Object? artists = json['artists'];
    final Object? albums = json['albums'];
    final Object? favorites = json['favorites'];
    expect(songs, isA<List<dynamic>>());
    expect(artists, isA<List<dynamic>>());
    expect(albums, isA<List<dynamic>>());
    expect(favorites, isA<Map<String, dynamic>>());
    final Map<String, dynamic> song = (songs! as List<dynamic>).single as Map<String, dynamic>;
    final Map<String, dynamic> artist =
        (artists! as List<dynamic>).first as Map<String, dynamic>;
    final Map<String, dynamic> album =
        (albums! as List<dynamic>).single as Map<String, dynamic>;
    final Map<String, dynamic> fav = favorites! as Map<String, dynamic>;
    expect(song['id'], session.library.songs.single.id);
    expect(song['audio_file_id'], isA<String>());
    expect(song['updated_at'], isA<String>());
    expect(artist['id'], isA<String>());
    expect(artist['updated_at'], isA<String>());
    expect(album['id'], session.library.albums.single.id);
    expect(album['updated_at'], isA<String>());
    expect(fav['song_ids'], <String>[session.library.songs.single.id]);
    expect(fav['updated_at'], isA<String>());
    expect(json.containsKey('local_audio_path'), isFalse);
    expect(song.containsKey('local_audio_path'), isFalse);
  });

  test('Manifest 上传成功后记下 manifestFileId 并删除上一份', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession session = _session(storeFiles, localDisk);
    await session.login(username: 'alice', password: 'password1');
    await session.importFile('/music/a.mp3');

    final List<FakeUploadedFile> first = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename == manifestFilename,
    );
    expect(first, hasLength(1));
    expect(session.manifestFileId, first.single.id);
    expect(localDisk.storedLibrary?.manifestFileId, first.single.id);

    await session.editSong(session.library.songs.single, title: 'Renamed');

    final List<FakeUploadedFile> manifests = _named(
      storeFiles,
      (FakeUploadedFile file) => file.filename == manifestFilename,
    );
    expect(manifests, hasLength(2));
    expect(storeFiles.deletedFileIds, <String>[first.single.id]);
    expect(session.manifestFileId, manifests.last.id);
    expect(localDisk.storedLibrary?.manifestFileId, manifests.last.id);
  });

  test('恢复已登录会话时尝试同步 dirty 曲库', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.fileBytes['/music/a.mp3'] = Uint8List.fromList(<int>[1, 2, 3]);
    final LibrarySession first = _session(storeFiles, localDisk);
    await first.importFile('/music/a.mp3');
    expect(storeFiles.uploads, isEmpty);
    localDisk.storedTokens = await storeFiles.login(
      username: 'alice',
      password: 'password1',
    );

    final LibrarySession restored = _session(storeFiles, localDisk);
    await restored.restoreSession();

    expect(restored.currentUser?.username, 'alice');
    expect(
      _named(
        storeFiles,
        (FakeUploadedFile file) => file.filename.endsWith('.mp3'),
      ),
      hasLength(1),
    );
    expect(
      _named(
        storeFiles,
        (FakeUploadedFile file) => file.filename == manifestFilename,
      ),
      hasLength(1),
    );
    expect(restored.manifestFileId, isNotNull);
  });
}
