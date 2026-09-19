import 'package:audio_service/audio_service.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

/// 启动 Android 媒体通知，四键接到 LibrarySession。
Future<void> startAndroidPlayback(LibrarySession session) async {
  await AudioService.init(
    builder: () => _AndroidPlaybackHandler(session),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.linjiahao.music_app.audio',
      androidNotificationChannelName: '播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

final class _AndroidPlaybackHandler extends BaseAudioHandler with SeekHandler {
  _AndroidPlaybackHandler(this._session) {
    _session.playbackChanged.listen((_) {
      _publish();
    });
  }

  final LibrarySession _session;
  bool _active = false;

  @override
  Future<void> play() => _session.play();

  @override
  Future<void> pause() => _session.pause();

  @override
  Future<void> skipToNext() => _session.skipToNext();

  @override
  Future<void> skipToPrevious() => _session.skipToPrevious();

  @override
  Future<void> seek(Duration position) => _session.seek(position);

  void _publish() {
    final Song? song = _session.currentSong;
    if (song == null) {
      _active = false;
      mediaItem.add(null);
      playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      return;
    }
    final bool playing = _session.audioEngine.playing;
    if (!playing && !_active) {
      return;
    }
    _active = true;
    mediaItem.add(_item(song));
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const <int>[0, 1, 2],
        systemActions: const <MediaAction>{MediaAction.seek},
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: _session.audioEngine.position,
        queueIndex: _session.queueIndex,
      ),
    );
  }

  MediaItem _item(Song song) {
    final LibraryProjection library = _session.library;
    final Album album = library.albumOf(song);
    final String? coverPath = album.coverPath;
    return MediaItem(
      id: song.id,
      title: song.title,
      artist: library.artistOf(song).name,
      album: album.title,
      duration: _session.audioEngine.duration,
      artUri: coverPath == null ? null : Uri.file(coverPath),
    );
  }
}
