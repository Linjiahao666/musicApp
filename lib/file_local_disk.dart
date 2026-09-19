import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';
import 'package:path/path.dart' as p;

/// 将鉴权凭证与 Queue 写入应用支持目录。
final class FileLocalDisk implements LocalDisk {
  FileLocalDisk(this.root);

  final Directory root;

  File get _authFile => File('${root.path}/auth_tokens.json');

  File get _queueFile => File('${root.path}/queue.json');

  File get _libraryFile => File('${root.path}/library.json');

  @override
  String get libraryPath => p.join(root.path, 'library');

  Directory get _libraryDir => Directory(libraryPath);

  Directory get _coversDir => Directory(p.join(root.path, 'covers'));

  Directory get _audioCacheDir => Directory(p.join(root.path, 'audio_cache'));

  @override
  Future<void> saveAuthTokens(AuthTokens tokens) async {
    final File file = _authFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(tokens.toJson()));
  }

  @override
  Future<AuthTokens?> loadAuthTokens() async {
    final File file = _authFile;
    if (!file.existsSync()) {
      return null;
    }
    try {
      return AuthTokens.fromJson(_jsonObject(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> clearAuthTokens() async {
    final File file = _authFile;
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<String> copyIntoLibrary(String sourcePath) async {
    await _libraryDir.create(recursive: true);
    final String dest = _uniqueLibraryPath(p.basename(sourcePath));
    await File(sourcePath).copy(dest);
    return dest;
  }

  @override
  Future<List<String>> listLibraryPaths() async {
    if (!_libraryDir.existsSync()) {
      return <String>[];
    }
    return <String>[
      for (final FileSystemEntity entity in _libraryDir.listSync())
        if (entity is File && isLibraryAudioPath(entity.path)) entity.path,
    ];
  }

  @override
  Future<List<int>> readBytes(String path) {
    return File(path).readAsBytes();
  }

  @override
  Future<String> contentHash(String path) async {
    final List<int> bytes = await File(path).readAsBytes();
    return sha256.convert(bytes).toString();
  }

  @override
  Future<AudioTags> readTags(String path) async {
    try {
      return _audioTagsFrom(File(path));
    } catch (_) {
      return const AudioTags();
    }
  }

  @override
  Future<String?> readSidecarLyrics(String audioPath) async {
    final File file = File(p.setExtension(audioPath, '.lrc'));
    if (!file.existsSync()) {
      return null;
    }
    final String text = await file.readAsString();
    if (text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  @override
  Future<String?> saveCover({
    required String albumId,
    required List<int> bytes,
    int maxSide = coverLongestSide,
  }) async {
    final img.Image? decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      return null;
    }
    final List<int> jpeg = img.encodeJpg(_fitLongest(decoded, maxSide), quality: 85);
    await _coversDir.create(recursive: true);
    final File file = File(p.join(_coversDir.path, '$albumId.jpg'));
    await file.writeAsBytes(jpeg, flush: true);
    return file.path;
  }

  @override
  Future<List<String>> listAudioFiles(String folderPath) async {
    final Directory dir = Directory(folderPath);
    if (!dir.existsSync()) {
      return <String>[];
    }
    final List<String> found = <String>[];
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && isLibraryAudioPath(entity.path)) {
        found.add(entity.path);
      }
    }
    found.sort();
    return found;
  }

  @override
  Future<bool> isDirectory(String path) async {
    return Directory(path).existsSync();
  }

  @override
  Future<void> saveLibrary(LibrarySnapshot snapshot) async {
    final File file = _libraryFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(snapshot.toJson()));
  }

  @override
  Future<LibrarySnapshot?> loadLibrary() async {
    final File file = _libraryFile;
    if (!file.existsSync()) {
      return null;
    }
    try {
      return LibrarySnapshot.fromJson(_jsonObject(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveQueue(QueueState state) async {
    final File file = _queueFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  @override
  Future<QueueState?> loadQueue() async {
    final File file = _queueFile;
    if (!file.existsSync()) {
      return null;
    }
    try {
      return QueueState.fromJson(_jsonObject(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async {
    if (path.isEmpty) {
      return false;
    }
    return File(path).existsSync();
  }

  @override
  Future<String> writeAudioCache({
    required String songId,
    required String extension,
    required List<int> bytes,
  }) async {
    await _audioCacheDir.create(recursive: true);
    final String ext =
        extension.isEmpty || extension.startsWith('.') ? extension : '.$extension';
    final File file = File(p.join(_audioCacheDir.path, '$songId$ext'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<void> deletePath(String path) async {
    final File file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  String _uniqueLibraryPath(String basename) {
    final File dest = File(p.join(libraryPath, basename));
    if (!dest.existsSync()) {
      return dest.path;
    }
    final String stem = p.basenameWithoutExtension(basename);
    final String ext = p.extension(basename);
    return p.join(libraryPath, '$stem-${DateTime.now().microsecondsSinceEpoch}$ext');
  }
}

img.Image _fitLongest(img.Image image, int maxSide) {
  final int longest = image.width > image.height ? image.width : image.height;
  if (longest <= maxSide) {
    return image;
  }
  final double scale = maxSide / longest;
  return img.copyResize(
    image,
    width: (image.width * scale).round(),
    height: (image.height * scale).round(),
  );
}

AudioTags _audioTagsFrom(File file) {
  final Object tag = readAllMetadata(file, getImage: true);
  if (tag is Mp3Metadata) {
    return AudioTags(
      title: _nonBlank(tag.songName),
      artist: _nonBlank(tag.leadPerformer),
      album: _nonBlank(tag.album),
      albumArtist: _nonBlank(tag.bandOrOrchestra),
      trackNumber: tag.trackNumber,
      lyrics: _nonBlank(tag.lyric),
      coverBytes: _pictureBytes(tag.pictures),
    );
  }
  if (tag is VorbisMetadata) {
    return AudioTags(
      title: _firstNonBlank(tag.title),
      artist: _firstNonBlank(tag.artist),
      album: _firstNonBlank(tag.album),
      albumArtist: _firstNonBlank(tag.albumArtist),
      trackNumber: tag.trackNumber.isEmpty ? null : tag.trackNumber.first,
      lyrics: _nonBlank(tag.lyric),
      coverBytes: _pictureBytes(tag.pictures),
    );
  }
  if (tag is Mp4Metadata) {
    return AudioTags(
      title: _nonBlank(tag.title),
      artist: _nonBlank(tag.artist),
      album: _nonBlank(tag.album),
      trackNumber: tag.trackNumber,
      lyrics: _nonBlank(tag.lyrics),
      coverBytes: tag.picture?.bytes,
    );
  }
  if (tag is ApeMetadata) {
    return AudioTags(
      title: _nonBlank(tag.title),
      artist: _nonBlank(tag.artist),
      album: _nonBlank(tag.album),
      albumArtist: _nonBlank(tag.albumArtist),
      trackNumber: tag.trackNumber,
      lyrics: _nonBlank(tag.lyric),
      coverBytes: _pictureBytes(tag.pictures),
    );
  }
  if (tag is RiffMetadata) {
    return AudioTags(
      title: _nonBlank(tag.title),
      artist: _nonBlank(tag.artist),
      album: _nonBlank(tag.album),
      trackNumber: tag.trackNumber,
    );
  }
  final AudioMetadata meta = readMetadata(file, getImage: true);
  return AudioTags(
    title: _nonBlank(meta.title),
    artist: _nonBlank(meta.artist),
    album: _nonBlank(meta.album),
    albumArtist: _nonBlank(meta.albumArtist),
    trackNumber: meta.trackNumber,
    lyrics: _nonBlank(meta.lyrics),
    coverBytes: _pictureBytes(meta.pictures),
  );
}

List<int>? _pictureBytes(List<Picture> pictures) {
  if (pictures.isEmpty) {
    return null;
  }
  return pictures.first.bytes;
}

String? _firstNonBlank(List<String> values) {
  for (final String value in values) {
    final String? text = _nonBlank(value);
    if (text != null) {
      return text;
    }
  }
  return null;
}

String? _nonBlank(String? value) {
  if (value == null) {
    return null;
  }
  final String trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

Map<String, dynamic> _jsonObject(String text) {
  final Object? decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  throw const FormatException('文件不是 JSON 对象');
}
