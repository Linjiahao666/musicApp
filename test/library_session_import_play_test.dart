import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

LibrarySession _session({
  FakeLocalDisk? localDisk,
  FakeAudioEngine? audioEngine,
}) {
  return LibrarySession(
    storeFiles: FakeStoreFiles(),
    localDisk: localDisk ?? FakeLocalDisk(),
    audioEngine: audioEngine ?? FakeAudioEngine(),
  );
}

void main() {
  test('导入后拷入曲库目录，歌曲列表出现以文件名为标题的 Song', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = _session(localDisk: localDisk);

    await session.importFile('/music/demo.mp3');

    expect(localDisk.libraryPaths, <String>['/library/demo.mp3']);
    expect(session.library.songs, hasLength(1));
    final Song song = session.library.songs.single;
    expect(song.title, 'demo.mp3');
    expect(song.localAudioPath, '/library/demo.mp3');
  });

  test('未登录也可导入', () async {
    final LibrarySession session = _session();

    expect(session.currentUser, isNull);
    await session.importFile('/music/demo.mp3');

    expect(session.library.songs, isNotEmpty);
  });

  test('点播走 localAudioPath，并可暂停与拖进度', () async {
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(audioEngine: engine);

    await session.importFile('/music/demo.mp3');
    final Song song = session.library.songs.single;

    await session.playSong(song);
    expect(engine.localSource, song.localAudioPath);
    expect(engine.playing, isTrue);

    await session.pause();
    expect(engine.playing, isFalse);

    await session.seek(const Duration(seconds: 15));
    expect(engine.position, const Duration(seconds: 15));
  });

  test('恢复会话时从曲库路径投影已导入的 Song', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    await _session(localDisk: localDisk).importFile('/music/demo.mp3');

    final LibrarySession restored = _session(localDisk: localDisk);
    expect(restored.library.songs, isEmpty);

    await restored.restoreSession();

    expect(restored.library.songs.single.title, 'demo.mp3');
    expect(restored.library.songs.single.localAudioPath, '/library/demo.mp3');
  });
}
