import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';

void main() {
  test('空曲库投影不含 Song、Artist、Album', () {
    final LibrarySession session = LibrarySession(
      storeFiles: FakeStoreFiles(),
      localDisk: FakeLocalDisk(),
      audioEngine: FakeAudioEngine(),
    );
    final LibraryProjection library = session.library;
    expect(library.songs, isEmpty);
    expect(library.artists, isEmpty);
    expect(library.albums, isEmpty);
  });
}
