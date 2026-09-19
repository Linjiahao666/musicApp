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
  test('导入无标签音频后投影占位 Artist 与 Album，Song 一对一归属', () async {
    final LibrarySession session = _session();

    await session.importFile('/music/demo.mp3');

    final LibraryProjection library = session.library;
    expect(library.artists.single.name, '未知歌手');
    expect(library.albums.single.title, '未知专辑');
    final Song song = library.songs.single;
    expect(song.artistId, library.artists.single.id);
    expect(song.albumId, library.albums.single.id);
  });

  test('两首无标签 Song 共用同一占位 Artist 与 Album', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection library = session.library;
    expect(library.artists, hasLength(1));
    expect(library.albums, hasLength(1));
    expect(library.songs, hasLength(2));
  });

  test('可按 Album 浏览其下 Song', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection library = session.library;
    final List<Song> songs = library.songsOfAlbum(library.albums.single.id);

    expect(songs.map((Song song) => song.title), <String>['alpha.mp3', 'beta.mp3']);
  });

  test('可按 Artist 浏览其下 Song', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection library = session.library;
    final List<Song> songs = library.songsOfArtist(library.artists.single.id);

    expect(songs.map((Song song) => song.title), <String>['alpha.mp3', 'beta.mp3']);
  });

  test('当前列表按标题子串过滤', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection shown = session.filter('ALP');

    expect(shown.songs.single.title, 'alpha.mp3');
  });

  test('当前列表按歌手名子串过滤', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    expect(session.filter('未知歌手').songs, hasLength(2));
    expect(session.filter('xyz').songs, isEmpty);
  });

  test('当前列表按专辑名子串过滤', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection shown = session.filter('未知专辑');

    expect(shown.albums.single.title, '未知专辑');
    expect(shown.songs, hasLength(2));
  });

  test('空白过滤词返回完整投影', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    expect(session.filter('  ').songs, hasLength(2));
  });

  test('过滤后仍可按 Album、Artist 浏览匹配的 Song', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/alpha.mp3');
    await session.importFile('/music/beta.mp3');

    final LibraryProjection shown = session.filter('alp');
    expect(shown.songsOfAlbum(shown.albums.single.id).single.title, 'alpha.mp3');
    expect(shown.songsOfArtist(shown.artists.single.id).single.title, 'alpha.mp3');
    expect(shown.albums.single.title, '未知专辑');
    expect(shown.artists.single.name, '未知歌手');
  });

  test('恢复会话后仍投影占位 Artist 与 Album', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    await _session(localDisk: localDisk).importFile('/music/demo.mp3');

    final LibrarySession restored = _session(localDisk: localDisk);
    await restored.restoreSession();

    expect(restored.library.artists.single.name, '未知歌手');
    expect(restored.library.albums.single.title, '未知专辑');
  });
}
