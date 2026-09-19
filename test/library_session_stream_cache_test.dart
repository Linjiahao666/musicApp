import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

final class _Env {
  const _Env({
    required this.session,
    required this.store,
    required this.engine,
    required this.disk,
  });

  final LibrarySession session;
  final FakeStoreFiles store;
  final FakeAudioEngine engine;
  final FakeLocalDisk disk;
}

Song _song({
  required String id,
  required String fileId,
  String title = '云端',
  String localAudioPath = '',
  String cachedAudioPath = '',
  int cachedSizeBytes = 0,
  bool pinned = false,
}) {
  return Song(
    id: id,
    title: title,
    localAudioPath: localAudioPath,
    cachedAudioPath: cachedAudioPath,
    cachedSizeBytes: cachedSizeBytes,
    isPinnedDownload: pinned,
    artistId: 'ar',
    albumId: 'al',
    audioFileId: fileId,
    syncState: SyncState.synced,
  );
}

Future<_Env> _open({
  required List<Song> songs,
  Map<String, List<int>> remoteBytes = const <String, List<int>>{},
  Map<String, List<int>> localBytes = const <String, List<int>>{},
  int? cacheLimit,
  String? coverPath,
  List<int>? coverBytes,
}) async {
  final FakeStoreFiles store = FakeStoreFiles();
  final FakeLocalDisk disk = FakeLocalDisk();
  final FakeAudioEngine engine = FakeAudioEngine();
  final AuthTokens tokens = await store.login(
    username: 'alice',
    password: 'password1',
  );
  remoteBytes.forEach((String fileId, List<int> bytes) {
    store.putFile(id: fileId, filename: '$fileId.mp3', bytes: bytes);
  });
  localBytes.forEach((String path, List<int> bytes) {
    disk.fileBytes[path] = List<int>.of(bytes);
    if (!path.startsWith('/cache/')) {
      disk.libraryPaths.add(path);
    }
  });
  if (coverPath != null && coverBytes != null) {
    disk.fileBytes[coverPath] = List<int>.of(coverBytes);
  }
  disk.storedTokens = tokens;
  disk.storedLibrary = LibrarySnapshot(
    songs: songs,
    artists: <Artist>[Artist(id: 'ar', name: '歌手', syncState: SyncState.synced)],
    albums: <Album>[
      Album(
        id: 'al',
        title: '专辑',
        coverPath: coverPath,
        syncState: SyncState.synced,
      ),
    ],
    cacheLimitBytes: cacheLimit ?? defaultAudioCacheLimitBytes,
  );
  final LibrarySession session = LibrarySession(
    storeFiles: store,
    localDisk: disk,
    audioEngine: engine,
  );
  await session.restoreSession();
  return _Env(session: session, store: store, engine: engine, disk: disk);
}

void main() {
  test('无本机无缓存时用文件访问令牌按字节范围播放并写入缓存', () async {
    final _Env env = await _open(
      songs: <Song>[_song(id: 's1', fileId: 'audio-1')],
      remoteBytes: <String, List<int>>{
        'audio-1': <int>[1, 2, 3, 4, 5],
      },
    );

    await env.session.playSong(env.session.library.songs.single);

    expect(env.engine.remoteSource, 'fake://files/audio-1/content');
    expect(
      env.engine.remoteHeaders['Authorization'],
      startsWith('Bearer file-access-'),
    );
    expect(env.store.rangeRequests, hasLength(1));
    expect(env.store.rangeRequests.single.fileId, 'audio-1');
    expect(env.store.rangeRequests.single.range, 'bytes=0-');
    expect(env.engine.playing, isTrue);

    final Song cached = env.session.library.songs.single;
    expect(cached.cachedAudioPath, '/cache/s1.mp3');
    expect(cached.cachedSizeBytes, 5);
    expect(env.disk.fileBytes['/cache/s1.mp3'], <int>[1, 2, 3, 4, 5]);
    expect(cached.needsNetwork, isFalse);
  });

  test('再次点播走缓存，不再请求云端', () async {
    final _Env env = await _open(
      songs: <Song>[_song(id: 's1', fileId: 'audio-1')],
      remoteBytes: <String, List<int>>{
        'audio-1': <int>[9, 8, 7],
      },
    );
    await env.session.playSong(env.session.library.songs.single);
    env.store.rangeRequests.clear();

    await env.session.playSong(env.session.library.songs.single);

    expect(env.engine.localSource, '/cache/s1.mp3');
    expect(env.engine.remoteSource, isNull);
    expect(env.store.rangeRequests, isEmpty);
  });

  test('本机文件优先于缓存与云端 Range', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(
          id: 's1',
          fileId: 'audio-1',
          localAudioPath: '/library/s1.mp3',
          cachedAudioPath: '/cache/s1.mp3',
          cachedSizeBytes: 3,
        ),
      ],
      remoteBytes: <String, List<int>>{
        'audio-1': <int>[1, 2, 3],
      },
      localBytes: <String, List<int>>{
        '/library/s1.mp3': <int>[1, 1, 1],
        '/cache/s1.mp3': <int>[2, 2, 2],
      },
    );

    await env.session.playSong(env.session.library.songs.single);

    expect(env.engine.localSource, '/library/s1.mp3');
    expect(env.engine.remoteSource, isNull);
    expect(env.store.rangeRequests, isEmpty);
  });

  test('无本机时缓存优先于云端 Range', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(
          id: 's1',
          fileId: 'audio-1',
          cachedAudioPath: '/cache/s1.mp3',
          cachedSizeBytes: 2,
        ),
      ],
      remoteBytes: <String, List<int>>{
        'audio-1': <int>[4, 5],
      },
      localBytes: <String, List<int>>{
        '/cache/s1.mp3': <int>[4, 5],
      },
    );

    await env.session.playSong(env.session.library.songs.single);

    expect(env.engine.localSource, '/cache/s1.mp3');
    expect(env.engine.remoteSource, isNull);
    expect(env.store.rangeRequests, isEmpty);
  });

  test('默认 2GB 上限可改，超额按访问次序淘汰未固定缓存', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(id: 'a', fileId: 'fa', title: 'A'),
        _song(id: 'b', fileId: 'fb', title: 'B'),
        _song(id: 'c', fileId: 'fc', title: 'C'),
      ],
      remoteBytes: <String, List<int>>{
        'fa': <int>[1, 1, 1, 1, 1],
        'fb': <int>[2, 2, 2, 2, 2],
        'fc': <int>[3, 3, 3, 3, 3],
      },
    );
    expect(env.session.cacheLimitBytes, defaultAudioCacheLimitBytes);

    await env.session.setCacheLimitBytes(10);
    final List<Song> songs = env.session.library.songs;
    await env.session.playSong(songs[0]);
    await env.session.playSong(songs[1]);
    await env.session.playSong(songs[2]);

    final LibraryProjection library = env.session.library;
    expect(library.songs[0].cachedAudioPath, isEmpty);
    expect(library.songs[1].cachedAudioPath, '/cache/b.mp3');
    expect(library.songs[2].cachedAudioPath, '/cache/c.mp3');
    expect(env.session.cacheUsageBytes, 10);
    expect(env.disk.fileBytes.containsKey('/cache/a.mp3'), isFalse);
  });

  test('isPinnedDownload 不参与淘汰，固定下载会写入缓存', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(id: 'a', fileId: 'fa', title: 'A'),
        _song(id: 'b', fileId: 'fb', title: 'B'),
        _song(id: 'c', fileId: 'fc', title: 'C'),
      ],
      remoteBytes: <String, List<int>>{
        'fa': <int>[1, 1, 1, 1, 1],
        'fb': <int>[2, 2, 2, 2, 2],
        'fc': <int>[3, 3, 3, 3, 3],
      },
    );
    await env.session.setCacheLimitBytes(10);
    final List<Song> songs = env.session.library.songs;

    await env.session.pinDownload(songs[0]);
    await env.session.playSong(env.session.library.songs[1]);
    await env.session.playSong(env.session.library.songs[2]);

    final LibraryProjection library = env.session.library;
    expect(library.songs[0].isPinnedDownload, isTrue);
    expect(library.songs[0].cachedAudioPath, '/cache/a.mp3');
    expect(library.songs[1].cachedAudioPath, isEmpty);
    expect(library.songs[2].cachedAudioPath, '/cache/c.mp3');
    expect(env.session.cacheUsageBytes, 10);
  });

  test('仅云端无缓存无本机时标记需联网，离线投影不含该 Song', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(id: 'cloud', fileId: 'fa', title: '云'),
        _song(
          id: 'local',
          fileId: 'fb',
          title: '本机',
          localAudioPath: '/library/local.mp3',
        ),
      ],
      remoteBytes: <String, List<int>>{
        'fa': <int>[1],
        'fb': <int>[2],
      },
      localBytes: <String, List<int>>{
        '/library/local.mp3': <int>[2],
      },
    );

    expect(env.session.library.songs[0].needsNetwork, isTrue);
    expect(env.session.library.songs[1].needsNetwork, isFalse);
    expect(
      env.session.offlineLibrary.songs.map((Song song) => song.id),
      <String>['local'],
    );

    await env.session.playSong(env.session.library.songs[0]);

    expect(env.session.library.songs[0].needsNetwork, isFalse);
    expect(
      env.session.offlineLibrary.songs.map((Song song) => song.id),
      <String>['cloud', 'local'],
    );
  });

  test('点播缓存会刷新访问次序，超额时淘汰更早未用项', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(id: 'a', fileId: 'fa', title: 'A'),
        _song(id: 'b', fileId: 'fb', title: 'B'),
        _song(id: 'c', fileId: 'fc', title: 'C'),
      ],
      remoteBytes: <String, List<int>>{
        'fa': <int>[1, 1, 1, 1, 1],
        'fb': <int>[2, 2, 2, 2, 2],
        'fc': <int>[3, 3, 3, 3, 3],
      },
    );
    await env.session.setCacheLimitBytes(10);
    final List<Song> songs = env.session.library.songs;
    await env.session.playSong(songs[0]);
    await env.session.playSong(songs[1]);
    await env.session.playSong(env.session.library.songs[0]);
    await env.session.playSong(env.session.library.songs[2]);

    final LibraryProjection library = env.session.library;
    expect(library.songs[0].cachedAudioPath, '/cache/a.mp3');
    expect(library.songs[1].cachedAudioPath, isEmpty);
    expect(library.songs[2].cachedAudioPath, '/cache/c.mp3');
    expect(env.session.cacheUsageBytes, 10);
  });

  test('取消固定后超额缓存按上限淘汰', () async {
    final _Env env = await _open(
      songs: <Song>[
        _song(id: 'a', fileId: 'fa', title: 'A'),
        _song(id: 'b', fileId: 'fb', title: 'B'),
      ],
      remoteBytes: <String, List<int>>{
        'fa': <int>[1, 1, 1, 1, 1],
        'fb': <int>[2, 2, 2, 2, 2],
      },
    );
    await env.session.setCacheLimitBytes(5);
    final List<Song> songs = env.session.library.songs;
    await env.session.pinDownload(songs[0]);
    await env.session.pinDownload(songs[1]);
    expect(env.session.cacheUsageBytes, 10);

    await env.session.unpinDownload(env.session.library.songs[0]);

    expect(env.session.library.songs[0].isPinnedDownload, isFalse);
    expect(env.session.library.songs[0].cachedAudioPath, isEmpty);
    expect(env.session.library.songs[1].isPinnedDownload, isTrue);
    expect(env.session.library.songs[1].cachedAudioPath, '/cache/b.mp3');
    expect(env.session.cacheUsageBytes, 5);
  });

  test('恢复会话时读回音频缓存上限', () async {
    final _Env env = await _open(
      songs: <Song>[_song(id: 's1', fileId: 'audio-1')],
      cacheLimit: 1024,
    );

    expect(env.session.cacheLimitBytes, 1024);

    await env.session.setCacheLimitBytes(2048);
    final LibrarySession restored = LibrarySession(
      storeFiles: env.store,
      localDisk: env.disk,
      audioEngine: FakeAudioEngine(),
    );
    await restored.restoreSession();

    expect(restored.cacheLimitBytes, 2048);
  });

  test('Cover 不计入音频缓存用量', () async {
    final _Env env = await _open(
      songs: <Song>[_song(id: 's1', fileId: 'audio-1')],
      remoteBytes: <String, List<int>>{
        'audio-1': <int>[1, 2, 3, 4, 5],
      },
      coverPath: '/covers/al.jpg',
      coverBytes: List<int>.filled(1024, 7),
    );

    await env.session.playSong(env.session.library.songs.single);

    expect(env.session.cacheUsageBytes, 5);
    expect(env.disk.fileBytes['/covers/al.jpg'], hasLength(1024));
  });
}
