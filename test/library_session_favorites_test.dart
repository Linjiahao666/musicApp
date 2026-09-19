import 'dart:convert';

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

Future<List<Song>> _importThree(LibrarySession session) async {
  await session.importFile('/music/a.mp3');
  await session.importFile('/music/b.mp3');
  await session.importFile('/music/c.mp3');
  return session.library.songs;
}

void main() {
  test('加入 Favorites 按加入顺序保留 Song id', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);

    await session.addToFavorites(songs[1]);
    await session.addToFavorites(songs[0]);

    expect(session.favorites.songIds, <String>[songs[1].id, songs[0].id]);
    expect(session.isFavorite(songs[1].id), isTrue);
    expect(session.isFavorite(songs[2].id), isFalse);
    expect(session.favoriteSongs().map((Song song) => song.id), <String>[
      songs[1].id,
      songs[0].id,
    ]);
  });

  test('移出 Favorites 去掉该 id，其余顺序不变', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.addToFavorites(songs[0]);
    await session.addToFavorites(songs[1]);
    await session.addToFavorites(songs[2]);

    await session.removeFromFavorites(songs[1]);

    expect(session.favorites.songIds, <String>[songs[0].id, songs[2].id]);
    expect(session.isFavorite(songs[1].id), isFalse);
  });

  test('重复加入同一 Song 不改变顺序与 updatedAt', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.addToFavorites(songs[0]);
    await session.addToFavorites(songs[1]);
    final DateTime updatedAt = session.favorites.updatedAt;

    await session.addToFavorites(songs[0]);

    expect(session.favorites.songIds, <String>[songs[0].id, songs[1].id]);
    expect(session.favorites.updatedAt, updatedAt);
  });

  test('加入与移出后 Favorites 的 updatedAt 前进', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    expect(session.favorites.updatedAt.millisecondsSinceEpoch, 0);

    await session.addToFavorites(songs[0]);
    final DateTime afterAdd = session.favorites.updatedAt;
    expect(afterAdd.millisecondsSinceEpoch, greaterThan(0));

    await session.removeFromFavorites(songs[0]);
    expect(
      session.favorites.updatedAt.isAfter(afterAdd) ||
          session.favorites.updatedAt.isAtSameMomentAs(afterAdd),
      isTrue,
    );
    expect(session.favorites.songIds, isEmpty);
  });

  test('删除 Song 时从 Favorites 去掉该 id', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.addToFavorites(songs[0]);
    await session.addToFavorites(songs[1]);
    await session.addToFavorites(songs[2]);
    final DateTime updatedAt = session.favorites.updatedAt;

    await session.deleteSong(songs[1]);

    expect(session.favorites.songIds, <String>[songs[0].id, songs[2].id]);
    expect(
      session.favorites.updatedAt.isAfter(updatedAt) ||
          session.favorites.updatedAt.isAtSameMomentAs(updatedAt),
      isTrue,
    );
  });

  test('删除未收藏的 Song 不改 Favorites', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.addToFavorites(songs[0]);
    final DateTime updatedAt = session.favorites.updatedAt;

    await session.deleteSong(songs[2]);

    expect(session.favorites.songIds, <String>[songs[0].id]);
    expect(session.favorites.updatedAt, updatedAt);
  });

  test('Favorites 写入曲库快照，恢复会话后仍是同一有序 Song id 与 updatedAt', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = _session(localDisk: localDisk);
    final List<Song> songs = await _importThree(session);
    await session.addToFavorites(songs[2]);
    await session.addToFavorites(songs[0]);

    expect(localDisk.storedLibrary?.favorites.songIds, <String>[
      songs[2].id,
      songs[0].id,
    ]);
    expect(
      localDisk.storedLibrary?.favorites.updatedAt,
      session.favorites.updatedAt,
    );

    final LibrarySession restored = _session(localDisk: localDisk);
    await restored.restoreSession();

    expect(restored.favorites.songIds, <String>[songs[2].id, songs[0].id]);
    expect(
      restored.favorites.updatedAt.isAtSameMomentAs(session.favorites.updatedAt),
      isTrue,
    );
    expect(restored.favoriteSongs().map((Song song) => song.id), <String>[
      songs[2].id,
      songs[0].id,
    ]);
  });

  test('曲库快照 JSON 含 Favorites 的有序 song_ids 与 updated_at', () {
    final Favorites favorites = Favorites(
      songIds: const <String>['b', 'a'],
      updatedAt: DateTime.utc(2026, 9, 17, 12),
    );
    final Map<String, dynamic> json = jsonDecode(
      jsonEncode(LibrarySnapshot(favorites: favorites).toJson()),
    ) as Map<String, dynamic>;
    final Object? raw = json['favorites'];
    expect(raw, isA<Map<String, dynamic>>());
    final Favorites parsed = Favorites.fromJson(raw! as Map<String, dynamic>);
    expect(parsed.songIds, <String>['b', 'a']);
    expect(parsed.updatedAt.isAtSameMomentAs(DateTime.utc(2026, 9, 17, 12)), isTrue);
  });
}
