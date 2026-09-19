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

Future<List<Song>> _importThree(LibrarySession session) async {
  await session.importFile('/music/a.mp3');
  await session.importFile('/music/b.mp3');
  await session.importFile('/music/c.mp3');
  return session.library.songs;
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('点播用当前视图整表替换 Queue 并从点中项开始', () async {
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(audioEngine: engine);
    final List<Song> songs = await _importThree(session);
    final List<Song> view = <Song>[songs[1], songs[2], songs[0]];

    await session.playFromView(view, songs[2]);

    expect(session.queue, <String>[songs[1].id, songs[2].id, songs[0].id]);
    expect(session.queueIndex, 1);
    expect(session.currentSong?.id, songs[2].id);
    expect(engine.localSource, songs[2].localAudioPath);
    expect(engine.playing, isTrue);
  });

  test('下一首播放插到当前项之后，其余 Queue 顺序不变', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.playFromView(<Song>[songs[0], songs[1]], songs[0]);

    await session.playNext(songs[2]);

    expect(session.queue, <String>[songs[0].id, songs[2].id, songs[1].id]);
    expect(session.currentSong?.id, songs[0].id);
  });

  test('加到队尾追加在 Queue 末尾', () async {
    final LibrarySession session = _session();
    final List<Song> songs = await _importThree(session);
    await session.playFromView(<Song>[songs[0], songs[1]], songs[0]);

    await session.appendToQueue(songs[2]);

    expect(session.queue, <String>[songs[0].id, songs[1].id, songs[2].id]);
    expect(session.currentSong?.id, songs[0].id);
  });

  test('随机是 AudioEngine 模式标志，skip 不打乱 Queue 顺序', () async {
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(audioEngine: engine);
    final List<Song> songs = await _importThree(session);
    await session.playFromView(songs, songs[0]);
    final List<String> original = List<String>.of(session.queue);

    await session.setShuffleEnabled(true);
    await session.skipToNext();

    expect(engine.shuffleEnabled, isTrue);
    expect(session.queue, original);
    expect(session.currentSong?.id, isNot(songs[0].id));
  });

  test('单曲循环播完后停留在当前 Queue 项', () async {
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(audioEngine: engine);
    final List<Song> songs = await _importThree(session);
    await session.playFromView(songs, songs[0]);
    await session.setRepeatMode(RepeatMode.one);

    engine.finishCurrent();
    await _flush();

    expect(session.currentSong?.id, songs[0].id);
    expect(session.queue, <String>[songs[0].id, songs[1].id, songs[2].id]);
    expect(engine.playing, isTrue);
  });

  test('列表循环在队尾播完后回到第一项', () async {
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(audioEngine: engine);
    final List<Song> songs = await _importThree(session);
    await session.playFromView(songs, songs[2]);

    engine.finishCurrent();
    await _flush();

    expect(session.currentSong?.id, songs[0].id);
    expect(session.queue, <String>[songs[0].id, songs[1].id, songs[2].id]);
  });

  test('Queue 写入本机，恢复会话后仍是同一有序 Song id 与进度', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final FakeAudioEngine engine = FakeAudioEngine();
    final LibrarySession session = _session(
      localDisk: localDisk,
      audioEngine: engine,
    );
    final List<Song> songs = await _importThree(session);
    await session.playFromView(songs, songs[1]);
    await session.seek(const Duration(seconds: 12));
    await session.setShuffleEnabled(true);
    await session.setRepeatMode(RepeatMode.one);

    expect(localDisk.storedQueue?.songIds, session.queue);
    expect(localDisk.storedQueue?.currentIndex, 1);

    final FakeAudioEngine restoredEngine = FakeAudioEngine();
    final LibrarySession restored = _session(
      localDisk: localDisk,
      audioEngine: restoredEngine,
    );
    await restored.restoreSession();

    expect(restored.queue, <String>[songs[0].id, songs[1].id, songs[2].id]);
    expect(restored.queueIndex, 1);
    expect(restored.currentSong?.id, songs[1].id);
    expect(restoredEngine.localSource, songs[1].localAudioPath);
    expect(restoredEngine.position, const Duration(seconds: 12));
    expect(restoredEngine.shuffleEnabled, isTrue);
    expect(restoredEngine.repeatMode, RepeatMode.one);
    expect(restoredEngine.playing, isFalse);
  });
}
