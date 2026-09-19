import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/fakes.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';

LibrarySession _session(FakeStoreFiles storeFiles, FakeLocalDisk localDisk) {
  return LibrarySession(
    storeFiles: storeFiles,
    localDisk: localDisk,
    audioEngine: FakeAudioEngine(),
  );
}

AuthTokens _expired(AuthTokens tokens) {
  return AuthTokens(
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
  );
}

void main() {
  test('登录成功后当前用户投影含用户名', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = _session(storeFiles, localDisk);

    await session.login(username: 'alice', password: 'password1');

    expect(session.currentUser?.username, 'alice');
    expect(localDisk.storedTokens, isNotNull);
    expect(storeFiles.refreshCount, 0);
  });

  test('Access 过期后自动 refresh 并保持登录', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession first = _session(storeFiles, localDisk);
    await first.login(username: 'alice', password: 'password1');
    localDisk.storedTokens = _expired(localDisk.storedTokens!);

    final LibrarySession restored = _session(storeFiles, localDisk);
    await restored.restoreSession();

    expect(storeFiles.refreshCount, 1);
    expect(restored.currentUser?.username, 'alice');
  });

  test('refresh 失败后当前用户为空需重新登录', () async {
    final FakeStoreFiles storeFiles = FakeStoreFiles();
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession first = _session(storeFiles, localDisk);
    await first.login(username: 'alice', password: 'password1');
    localDisk.storedTokens = _expired(localDisk.storedTokens!);
    storeFiles.failRefresh = true;

    final LibrarySession restored = _session(storeFiles, localDisk);
    await restored.restoreSession();

    expect(restored.currentUser, isNull);
    expect(localDisk.storedTokens, isNull);
  });

  test('注册成功后当前用户投影可用', () async {
    final LibrarySession session = _session(FakeStoreFiles(), FakeLocalDisk());

    await session.register(username: 'bob', password: 'password1');

    expect(session.currentUser?.username, 'bob');
  });

  test('登出后清除当前用户与本机凭证', () async {
    final FakeLocalDisk localDisk = FakeLocalDisk();
    final LibrarySession session = _session(FakeStoreFiles(), localDisk);
    await session.login(username: 'alice', password: 'password1');

    await session.logout();

    expect(session.currentUser, isNull);
    expect(localDisk.storedTokens, isNull);
  });
}
