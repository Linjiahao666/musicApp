import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

LibrarySession _session({FakeLocalDisk? localDisk}) {
  return LibrarySession(
    storeFiles: FakeStoreFiles(),
    localDisk: localDisk ?? FakeLocalDisk(),
    audioEngine: FakeAudioEngine(),
  );
}

void main() {
  test('标签填标题、主歌手、Album 名、Album Artist 与曲序', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Karma Police',
      artist: 'Radiohead',
      album: 'OK Computer',
      albumArtist: 'Radiohead',
      trackNumber: 6,
    );
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');

    final LibraryProjection library = session.library;
    final Song song = library.songs.single;
    expect(song.title, 'Karma Police');
    expect(song.trackNumber, 6);
    expect(library.artistOf(song).name, 'Radiohead');
    expect(library.albumOf(song).title, 'OK Computer');
    expect(song.albumArtistId, song.artistId);
  });

  test('Album Artist 与主歌手不同时各自投影为 Artist', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Song',
      artist: 'Guest',
      album: 'Hits',
      albumArtist: 'Various Artists',
    );
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');

    final LibraryProjection library = session.library;
    final Song song = library.songs.single;
    expect(library.artistOf(song).name, 'Guest');
    expect(song.albumArtistId, isNot(song.artistId));
    expect(
      library.artists.map((Artist artist) => artist.name),
      containsAll(<String>['Guest', 'Various Artists']),
    );
    expect(library.albumOf(song).artistId, song.albumArtistId);
  });

  test('缺标签时标题用文件名，并投影占位 Artist 与 Album', () async {
    final LibrarySession session = _session();

    await session.importFile('/music/demo.mp3');

    final LibraryProjection library = session.library;
    expect(library.songs.single.title, 'demo.mp3');
    expect(library.artists.single.name, unknownArtistName);
    expect(library.albums.single.title, unknownAlbumTitle);
  });

  test('内嵌 Cover 挂在 Album 上，写入最长边 512 的 JPEG', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      album: 'OK Computer',
      albumArtist: 'Radiohead',
      coverBytes: const <int>[255, 216, 255],
    );
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');

    final Album album = session.library.albums.single;
    expect(album.coverPath, endsWith('.jpg'));
    expect(localDisk.lastCoverMaxSide, coverLongestSide);
    expect(localDisk.savedCovers[album.id], isNotEmpty);
  });

  test('无 Cover 时 Album 不挂封面路径，供占位展示', () async {
    final LibrarySession session = _session();

    await session.importFile('/music/demo.mp3');

    expect(session.library.albums.single.coverPath, isNull);
  });

  test('同目录歌词 sidecar 优先于内嵌 Lyrics', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(lyrics: '内嵌');
    localDisk.sidecarLyrics['/music/a.mp3'] = 'sidecar';
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');

    expect(session.library.songs.single.lyrics, 'sidecar');
  });

  test('无 sidecar 时使用内嵌 Lyrics，供播放页显示', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(lyrics: '内嵌歌词');
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');
    final Song song = session.library.songs.single;
    await session.playSong(song);

    expect(session.currentSong?.lyrics, '内嵌歌词');
  });

  test('文件夹递归列出的音频一并导入', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.folderAudioFiles['/album'] = <String>[
      '/album/a.mp3',
      '/album/disc2/b.flac',
    ];
    final LibrarySession session = _session(localDisk: localDisk);

    final ImportResult result = await session.importFolder('/album');

    expect(result.importedCount, 2);
    expect(session.library.songs, hasLength(2));
  });

  test('拖拽目录与文件一并导入', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.directories.add('/album');
    localDisk.folderAudioFiles['/album'] = <String>['/album/a.mp3'];
    final LibrarySession session = _session(localDisk: localDisk);

    final ImportResult result = await session.importDropped(<String>[
      '/album',
      '/music/b.mp3',
    ]);

    expect(result.importedCount, 2);
    expect(session.library.songs, hasLength(2));
  });

  test('相同内容哈希跳过导入并计入重复', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.hashes['/music/a.mp3'] = 'same-bytes';
    localDisk.hashes['/other/copy.mp3'] = 'same-bytes';
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');
    final ImportResult result = await session.importFile('/other/copy.mp3');

    expect(session.library.songs, hasLength(1));
    expect(result.importedCount, 0);
    expect(result.duplicateCount, 1);
    expect(localDisk.libraryPaths, <String>['/library/a.mp3']);
  });

  test('同一 Album 名与 Album Artist 共用 Album 与 Cover', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Airbag',
      artist: 'Radiohead',
      album: 'OK Computer',
      albumArtist: 'Radiohead',
      coverBytes: const <int>[1, 2, 3],
    );
    localDisk.tagsByPath['/music/b.mp3'] = const AudioTags(
      title: 'Paranoid Android',
      artist: 'Radiohead',
      album: 'OK Computer',
      albumArtist: 'Radiohead',
    );
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');
    await session.importFile('/music/b.mp3');

    expect(session.library.albums, hasLength(1));
    expect(session.library.artists, hasLength(1));
    expect(session.library.albums.single.coverPath, isNotNull);
  });

  test('恢复会话后仍保留标签、Cover 与 Lyrics', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Karma Police',
      artist: 'Radiohead',
      album: 'OK Computer',
      lyrics: '内嵌歌词',
      coverBytes: const <int>[9, 8, 7],
    );
    await _session(localDisk: localDisk).importFile('/music/a.mp3');

    final LibrarySession restored = _session(localDisk: localDisk);
    await restored.restoreSession();

    final Song song = restored.library.songs.single;
    expect(song.title, 'Karma Police');
    expect(song.lyrics, '内嵌歌词');
    expect(restored.library.artistOf(song).name, 'Radiohead');
    expect(restored.library.albumOf(song).coverPath, isNotNull);
  });
}
