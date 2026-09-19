import 'package:just_audio/just_audio.dart';
import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';

/// 用 just_audio 播放本机曲库文件。
final class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  RepeatMode _repeatMode = RepeatMode.all;
  bool _shuffleEnabled = false;

  @override
  Future<void> setLocalSource(String path) async {
    await _player.setFilePath(path);
  }

  @override
  Future<void> setRemoteSource({
    required String url,
    Map<String, String> headers = const <String, String>{},
  }) async {
    await _player.setUrl(url, headers: headers.isEmpty ? null : headers);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  bool get playing => _player.playing;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  RepeatMode get repeatMode => _repeatMode;

  @override
  bool get shuffleEnabled => _shuffleEnabled;

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    _repeatMode = mode;
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    _shuffleEnabled = enabled;
  }

  @override
  Stream<void> get completed {
    return _player.processingStateStream
        .where((ProcessingState state) => state == ProcessingState.completed)
        .map((_) {});
  }
}
