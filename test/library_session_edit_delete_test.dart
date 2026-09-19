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

Future<LibrarySession> _importPair(FakeLocalDisk localDisk) async {
  localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
    title: 'Airbag',
    artist: 'Radiohead',
    album: 'OK Computer',
  );
  localDisk.tagsByPath['/music/b.mp3'] = const AudioTags(
    title: 'Paranoid Android',
    artist: 'Radiohead',
    album: 'OK Computer',
  );
  final LibrarySession session = _session(localDisk: localDisk);
  await session.importFile('/music/a.mp3');
  await session.importFile('/music/b.mp3');
  return session;
}

void main() {
  test('导入后 Song、Artist、Album 的 SyncState 为 dirty', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    localDisk.tagsByPath['/music/a.mp3'] = const AudioTags(
      title: 'Airbag',
      artist: 'Radiohead',
      album: 'OK Computer',
    );
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/a.mp3');

    final LibraryProjection library = session.library;
    expect(library.songs.single.syncState, SyncState.dirty);
    expect(library.artists.single.syncState, SyncState.dirty);
    expect(library.albums.single.syncState, SyncState.dirty);
  });

  test('改标题与主歌手只作用于该 Song', () async {
    final LibrarySession session = await _importPair(FakeLocalDisk());
    final Song first = session.library.songs.first;

    await session.editSong(first, title: '新标题', artistName: 'Thom');

    final LibraryProjection library = session.library;
    expect(library.songs.first.title, '新标题');
    expect(library.artistOf(library.songs.first).name, 'Thom');
    expect(library.songs.last.title, 'Paranoid Android');
    expect(library.artistOf(library.songs.last).name, 'Radiohead');
  });

  test('改专辑名作用在 Album 实体，同属 Song 展示一起变', () async {
    final LibrarySession session = await _importPair(FakeLocalDisk());
    final Song first = session.library.songs.first;

    await session.editSong(first, albumTitle: 'OKNOTOK');

    final LibraryProjection library = session.library;
    expect(library.albums.single.title, 'OKNOTOK');
    expect(
      library.songs.map((Song song) => library.albumOf(song).title),
      everyElement('OKNOTOK'),
    );
    expect(library.albums.single.syncState, SyncState.dirty);
  });

  test('改专辑名后可用新名过滤', () async {
    final LibrarySession session = await _importPair(FakeLocalDisk());

    await session.editSong(session.library.songs.first, albumTitle: 'OKNOTOK');

    expect(session.filter('OKNOTOK').songs, hasLength(2));
    expect(session.filter('OK Computer').songs, isEmpty);
  });

  test('删除后列表不再出现，SyncState 为 pendingDelete', () async {
    final LibrarySession session = _session();
    await session.importFile('/music/demo.mp3');
    final Song song = session.library.songs.single;

    await session.deleteSong(song);

    expect(session.library.songs, isEmpty);
    expect(session.library.artists, isEmpty);
    expect(session.library.albums, isEmpty);
    expect(session.songSyncState(song.id), SyncState.pendingDelete);
  });

  test('删除后 Album 与 Artist 浏览不再列出该 Song', () async {
    final LibrarySession session = await _importPair(FakeLocalDisk());
    final Song first = session.library.songs.first;
    final String albumId = first.albumId;
    final String artistId = first.artistId;

    await session.deleteSong(first);

    expect(session.library.songs, hasLength(1));
    expect(session.library.songsOfAlbum(albumId).single.title, 'Paranoid Android');
    expect(session.library.songsOfArtist(artistId).single.title, 'Paranoid Android');
  });

  test('删除后恢复会话列表仍不含该 Song，记录仍为 pendingDelete', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = _session(localDisk: localDisk);
    await session.importFile('/music/demo.mp3');
    final Song song = session.library.songs.single;
    await session.deleteSong(song);

    final LibrarySession restored = _session(localDisk: localDisk);
    await restored.restoreSession();

    expect(restored.library.songs, isEmpty);
    expect(restored.songSyncState(song.id), SyncState.pendingDelete);
  });

  test('编辑后恢复会话保留标题、主歌手与专辑名', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = await _importPair(localDisk);
    await session.editSong(
      session.library.songs.first,
      title: '新标题',
      artistName: 'Thom',
      albumTitle: 'OKNOTOK',
    );

    final LibrarySession restored = _session(localDisk: localDisk);
    await restored.restoreSession();

    final LibraryProjection library = restored.library;
    expect(library.songs.first.title, '新标题');
    expect(library.artistOf(library.songs.first).name, 'Thom');
    expect(library.albums.single.title, 'OKNOTOK');
    expect(library.albumOf(library.songs.last).title, 'OKNOTOK');
  });
}
