import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:music_app/android_playback.dart';
import 'package:music_app/file_local_disk.dart';
import 'package:music_app/http_store_files.dart';
import 'package:music_app/just_audio_engine.dart';
import 'package:music_app/library_session.dart';
import 'package:music_app/models.dart';
import 'package:music_app/ports.dart';
import 'package:path_provider/path_provider.dart';

const String storeBaseUrl = String.fromEnvironment(
  'STORE_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final Directory supportDir = await getApplicationSupportDirectory();
  final LibrarySession session = LibrarySession(
    storeFiles: HttpStoreFiles(baseUrl: storeBaseUrl),
    localDisk: FileLocalDisk(supportDir),
    audioEngine: JustAudioEngine(),
  );
  if (Platform.isAndroid) {
    await startAndroidPlayback(session);
  }
  runApp(MusicApp(session: session));
}

class MusicApp extends StatelessWidget {
  const MusicApp({super.key, required this.session});

  final LibrarySession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '曲库',
      home: _SessionGate(session: session),
    );
  }
}

class _SessionGate extends StatefulWidget {
  const _SessionGate({required this.session});

  final LibrarySession session;

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  bool _ready = false;
  StreamSubscription<void>? _playbackSub;

  @override
  void initState() {
    super.initState();
    _playbackSub = widget.session.playbackChanged.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    _restore();
  }

  @override
  void dispose() {
    _playbackSub?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    await widget.session.restoreSession();
    if (!mounted) {
      return;
    }
    setState(() => _ready = true);
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.session.currentUser == null) {
      return _AuthPage(session: widget.session, onChanged: _rebuild);
    }
    return _LibraryHome(session: widget.session, onChanged: _rebuild);
  }
}

class _AuthPage extends StatefulWidget {
  const _AuthPage({
    required this.session,
    required this.onChanged,
  });

  final LibrarySession session;
  final VoidCallback onChanged;

  @override
  State<_AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<_AuthPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool register}) async {
    final String username = _username.text.trim();
    final String password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (register) {
        await widget.session.register(username: username, password: password);
      } else {
        await widget.session.login(username: username, password: password);
      }
      if (!mounted) {
        return;
      }
      widget.onChanged();
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = _authMessage(error));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = '网络异常，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              storeBaseUrl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _username,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '用户名'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_busy) {
                  _submit(register: false);
                }
              },
            ),
            if (_error case final String error) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : () => _submit(register: false),
              child: const Text('登录'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _submit(register: true),
              child: const Text('注册'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _LibraryPane { songs, albums, artists, favorites }

enum _ImportKind { file, folder }

class _LibraryHome extends StatefulWidget {
  const _LibraryHome({
    required this.session,
    required this.onChanged,
  });

  final LibrarySession session;
  final VoidCallback onChanged;

  @override
  State<_LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<_LibraryHome> {
  LibrarySession get session => widget.session;
  _LibraryPane _pane = _LibraryPane.songs;
  Album? _openedAlbum;
  Artist? _openedArtist;
  String _query = '';

  bool get _atRoot => _openedAlbum == null && _openedArtist == null;

  String get _title {
    final Album? album = _openedAlbum;
    if (album != null) {
      return album.title;
    }
    final Artist? artist = _openedArtist;
    if (artist != null) {
      return artist.name;
    }
    return switch (_pane) {
      _LibraryPane.songs => '歌曲',
      _LibraryPane.albums => '专辑',
      _LibraryPane.artists => '歌手',
      _LibraryPane.favorites => '收藏',
    };
  }

  Future<void> _logout() async {
    await session.logout();
    widget.onChanged();
  }

  Future<void> _importFile() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (!mounted) {
      return;
    }
    if (picked == null || picked.files.isEmpty) {
      return;
    }
    await _runImport(
      () => session.importDropped(<String>[
        for (final PlatformFile file in picked.files)
          if (file.path != null) file.path!,
      ]),
    );
  }

  Future<void> _importFolder() async {
    final String? folder = await FilePicker.platform.getDirectoryPath();
    if (!mounted) {
      return;
    }
    if (folder == null) {
      return;
    }
    await _runImport(() => session.importFolder(folder));
  }

  Future<void> _importDropped(List<String> paths) {
    return _runImport(() => session.importDropped(paths));
  }

  Future<void> _runImport(Future<ImportResult> Function() action) async {
    try {
      final ImportResult result = await action();
      if (!mounted) {
        return;
      }
      widget.onChanged();
      if (result.duplicateCount == 0) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已跳过 ${result.duplicateCount} 首重复音频')),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入失败')),
      );
    }
  }

  Future<void> _playSong(Song song) async {
    await session.playFromView(_currentViewSongs(), song);
    widget.onChanged();
  }

  Future<void> _playNext(Song song) async {
    await session.playNext(song);
    if (!mounted) {
      return;
    }
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已设为下一首播放')),
    );
  }

  Future<void> _appendToQueue(Song song) async {
    await session.appendToQueue(song);
    if (!mounted) {
      return;
    }
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加到队尾')),
    );
  }

  Future<void> _togglePin(Song song) async {
    final bool pinned = song.isPinnedDownload;
    if (pinned) {
      await session.unpinDownload(song);
    } else {
      await session.pinDownload(song);
    }
    if (!mounted) {
      return;
    }
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(pinned ? '已取消固定下载' : '已固定下载')),
    );
  }

  Future<void> _toggleFavorite(Song song) async {
    final bool added = !session.isFavorite(song.id);
    if (added) {
      await session.addToFavorites(song);
    } else {
      await session.removeFromFavorites(song);
    }
    if (!mounted) {
      return;
    }
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(added ? '已加入收藏' : '已移出收藏')),
    );
  }

  Future<void> _editSong(Song song) async {
    final LibraryProjection library = session.library;
    final _SongDraft? draft = await showDialog<_SongDraft>(
      context: context,
      builder: (BuildContext context) {
        return _EditSongDialog(
          title: song.title,
          artistName: library.artistOf(song).name,
          albumTitle: library.albumOf(song).title,
        );
      },
    );
    if (draft == null || !mounted) {
      return;
    }
    await session.editSong(
      song,
      title: draft.title,
      artistName: draft.artistName,
      albumTitle: draft.albumTitle,
    );
    if (!mounted) {
      return;
    }
    setState(_syncOpened);
    widget.onChanged();
  }

  Future<void> _deleteSong(Song song) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除'),
          content: const Text('将从曲库列表中消失'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await session.deleteSong(song);
    if (!mounted) {
      return;
    }
    setState(_syncOpened);
    widget.onChanged();
  }

  void _syncOpened() {
    final Album? album = _openedAlbum;
    if (album != null) {
      _openedAlbum = _albumById(album.id);
    }
    final Artist? artist = _openedArtist;
    if (artist != null) {
      _openedArtist = _artistById(artist.id);
    }
  }

  Album? _albumById(String id) {
    for (final Album album in session.library.albums) {
      if (album.id == id) {
        return album;
      }
    }
    return null;
  }

  Artist? _artistById(String id) {
    for (final Artist artist in session.library.artists) {
      if (artist.id == id) {
        return artist;
      }
    }
    return null;
  }

  List<Song> _currentViewSongs() {
    return _visibleSongs(session.filter(_query)) ?? session.library.songs;
  }

  Future<void> _togglePlayback() async {
    if (session.audioEngine.playing) {
      await session.pause();
    } else {
      await session.play();
    }
    widget.onChanged();
  }

  Future<void> _skipToNext() async {
    await session.skipToNext();
    widget.onChanged();
  }

  Future<void> _skipToPrevious() async {
    await session.skipToPrevious();
    widget.onChanged();
  }

  Future<void> _cyclePlaybackMode() async {
    await session.cyclePlaybackMode();
    widget.onChanged();
  }

  void _openNowPlaying() {
    if (session.currentSong == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          return _NowPlayingPage(session: session, onChanged: widget.onChanged);
        },
      ),
    );
  }

  void _selectPane(_LibraryPane pane) {
    setState(() {
      _pane = pane;
      _openedAlbum = null;
      _openedArtist = null;
    });
  }

  void _openAlbum(Album album) {
    setState(() {
      _openedAlbum = album;
      _openedArtist = null;
    });
  }

  void _openArtist(Artist artist) {
    setState(() {
      _openedArtist = artist;
      _openedAlbum = null;
    });
  }

  void _popBrowse() {
    setState(() {
      _openedAlbum = null;
      _openedArtist = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final LibraryProjection shown = session.filter(_query);
    return DropTarget(
      onDragDone: (DropDoneDetails detail) {
        _importDropped(<String>[
          for (final DropItem file in detail.files) file.path,
        ]);
      },
      child: Scaffold(
      appBar: AppBar(
        leading: _atRoot
            ? null
            : IconButton(
                onPressed: _popBrowse,
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(_title),
        actions: <Widget>[
          PopupMenuButton<_ImportKind>(
            tooltip: '导入',
            onSelected: (_ImportKind kind) {
              switch (kind) {
                case _ImportKind.file:
                  _importFile();
                case _ImportKind.folder:
                  _importFolder();
              }
            },
            itemBuilder: (BuildContext context) {
              return const <PopupMenuItem<_ImportKind>>[
                PopupMenuItem<_ImportKind>(
                  value: _ImportKind.file,
                  child: Text('导入文件'),
                ),
                PopupMenuItem<_ImportKind>(
                  value: _ImportKind.folder,
                  child: Text('导入文件夹'),
                ),
              ];
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('导入'),
            ),
          ),
          TextButton(
            onPressed: _logout,
            child: const Text('登出'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (session.syncError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '同步失败，曲库尚未上云',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_atRoot) _PaneBar(pane: _pane, onSelect: _selectPane),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _FilterField(
              onChanged: (String value) {
                setState(() => _query = value);
              },
            ),
          ),
          Expanded(child: _browseList(shown)),
        ],
      ),
      bottomNavigationBar: session.currentSong == null
          ? null
          : _PlaybackBar(
              session: session,
              onToggle: _togglePlayback,
              onSeek: session.seek,
              onSkipNext: _skipToNext,
              onSkipPrevious: _skipToPrevious,
              onCycleMode: _cyclePlaybackMode,
              onOpenNowPlaying: _openNowPlaying,
            ),
      ),
    );
  }

  Widget _browseList(LibraryProjection shown) {
    final List<Song>? songs = _visibleSongs(shown);
    if (songs != null) {
      return _SongList(
        songs: songs,
        projection: shown,
        emptyLabel: _emptyLabel(
          _pane == _LibraryPane.favorites ? '暂无收藏' : '暂无歌曲',
        ),
        currentSongId: session.currentSong?.id,
        isFavorite: session.isFavorite,
        onPlay: _playSong,
        onPlayNext: _playNext,
        onAppend: _appendToQueue,
        onToggleFavorite: _toggleFavorite,
        onPinDownload: _togglePin,
        onEdit: _editSong,
        onDelete: _deleteSong,
      );
    }
    if (_pane == _LibraryPane.albums) {
      return _AlbumList(
        albums: shown.albums,
        projection: shown,
        emptyLabel: _emptyLabel('暂无专辑'),
        onOpen: _openAlbum,
      );
    }
    return _ArtistList(
      artists: shown.artists,
      projection: shown,
      emptyLabel: _emptyLabel('暂无歌手'),
      onOpen: _openArtist,
    );
  }

  List<Song>? _visibleSongs(LibraryProjection shown) {
    final Album? album = _openedAlbum;
    if (album != null) {
      return shown.songsOfAlbum(album.id);
    }
    final Artist? artist = _openedArtist;
    if (artist != null) {
      return shown.songsOfArtist(artist.id);
    }
    if (_pane == _LibraryPane.songs) {
      return shown.songs;
    }
    if (_pane == _LibraryPane.favorites) {
      return session.favoriteSongs(shown);
    }
    return null;
  }

  String _emptyLabel(String idle) {
    return _query.trim().isEmpty ? idle : '无匹配项';
  }
}

class _PaneBar extends StatelessWidget {
  const _PaneBar({
    required this.pane,
    required this.onSelect,
  });

  final _LibraryPane pane;
  final ValueChanged<_LibraryPane> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SegmentedButton<_LibraryPane>(
        showSelectedIcon: false,
        segments: const <ButtonSegment<_LibraryPane>>[
          ButtonSegment<_LibraryPane>(
            value: _LibraryPane.songs,
            label: Text('歌曲'),
          ),
          ButtonSegment<_LibraryPane>(
            value: _LibraryPane.albums,
            label: Text('专辑'),
          ),
          ButtonSegment<_LibraryPane>(
            value: _LibraryPane.artists,
            label: Text('歌手'),
          ),
          ButtonSegment<_LibraryPane>(
            value: _LibraryPane.favorites,
            label: Text('收藏'),
          ),
        ],
        selected: <_LibraryPane>{pane},
        onSelectionChanged: (Set<_LibraryPane> next) {
          onSelect(next.single);
        },
      ),
    );
  }
}

class _FilterField extends StatelessWidget {
  const _FilterField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      decoration: const InputDecoration(
        hintText: '按标题、歌手、专辑名过滤',
        prefixIcon: Icon(Icons.search),
        isDense: true,
      ),
      onChanged: onChanged,
    );
  }
}

enum _SongAction { playNext, append, favorite, pin, edit, delete }

class _SongList extends StatelessWidget {
  const _SongList({
    required this.songs,
    required this.projection,
    required this.emptyLabel,
    required this.currentSongId,
    required this.isFavorite,
    required this.onPlay,
    required this.onPlayNext,
    required this.onAppend,
    required this.onToggleFavorite,
    required this.onPinDownload,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Song> songs;
  final LibraryProjection projection;
  final String emptyLabel;
  final String? currentSongId;
  final bool Function(String songId) isFavorite;
  final ValueChanged<Song> onPlay;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAppend;
  final ValueChanged<Song> onToggleFavorite;
  final ValueChanged<Song> onPinDownload;
  final ValueChanged<Song> onEdit;
  final ValueChanged<Song> onDelete;

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return Center(child: Text(emptyLabel));
    }
    return ListView.builder(
      itemCount: songs.length,
      itemBuilder: (BuildContext context, int index) {
        final Song song = songs[index];
        return ListTile(
          title: Text(song.title),
          subtitle: Text(_songSubtitle(song, projection)),
          selected: currentSongId == song.id,
          onTap: () => onPlay(song),
          trailing: PopupMenuButton<_SongAction>(
            tooltip: '更多',
            onSelected: (_SongAction action) {
              switch (action) {
                case _SongAction.playNext:
                  onPlayNext(song);
                case _SongAction.append:
                  onAppend(song);
                case _SongAction.favorite:
                  onToggleFavorite(song);
                case _SongAction.pin:
                  onPinDownload(song);
                case _SongAction.edit:
                  onEdit(song);
                case _SongAction.delete:
                  onDelete(song);
              }
            },
            itemBuilder: (BuildContext context) {
              return <PopupMenuItem<_SongAction>>[
                const PopupMenuItem<_SongAction>(
                  value: _SongAction.playNext,
                  child: Text('下一首播放'),
                ),
                const PopupMenuItem<_SongAction>(
                  value: _SongAction.append,
                  child: Text('加到队尾'),
                ),
                PopupMenuItem<_SongAction>(
                  value: _SongAction.favorite,
                  child: Text(isFavorite(song.id) ? '移出收藏' : '加入收藏'),
                ),
                PopupMenuItem<_SongAction>(
                  value: _SongAction.pin,
                  child: Text(song.isPinnedDownload ? '取消固定下载' : '固定下载'),
                ),
                const PopupMenuItem<_SongAction>(
                  value: _SongAction.edit,
                  child: Text('编辑'),
                ),
                const PopupMenuItem<_SongAction>(
                  value: _SongAction.delete,
                  child: Text('删除'),
                ),
              ];
            },
          ),
        );
      },
    );
  }
}

class _AlbumList extends StatelessWidget {
  const _AlbumList({
    required this.albums,
    required this.projection,
    required this.emptyLabel,
    required this.onOpen,
  });

  final List<Album> albums;
  final LibraryProjection projection;
  final String emptyLabel;
  final ValueChanged<Album> onOpen;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return Center(child: Text(emptyLabel));
    }
    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (BuildContext context, int index) {
        final Album album = albums[index];
        return ListTile(
          leading: _CoverMark(album: album),
          title: Text(album.title),
          subtitle: Text('${projection.songsOfAlbum(album.id).length} 首'),
          onTap: () => onOpen(album),
        );
      },
    );
  }
}

class _ArtistList extends StatelessWidget {
  const _ArtistList({
    required this.artists,
    required this.projection,
    required this.emptyLabel,
    required this.onOpen,
  });

  final List<Artist> artists;
  final LibraryProjection projection;
  final String emptyLabel;
  final ValueChanged<Artist> onOpen;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return Center(child: Text(emptyLabel));
    }
    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (BuildContext context, int index) {
        final Artist artist = artists[index];
        return ListTile(
          title: Text(artist.name),
          subtitle: Text('${projection.songsOfArtist(artist.id).length} 首'),
          onTap: () => onOpen(artist),
        );
      },
    );
  }
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.session,
    required this.onToggle,
    required this.onSeek,
    required this.onSkipNext,
    required this.onSkipPrevious,
    required this.onCycleMode,
    required this.onOpenNowPlaying,
  });

  final LibrarySession session;
  final VoidCallback onToggle;
  final Future<void> Function(Duration position) onSeek;
  final VoidCallback onSkipNext;
  final VoidCallback onSkipPrevious;
  final VoidCallback onCycleMode;
  final VoidCallback onOpenNowPlaying;

  @override
  Widget build(BuildContext context) {
    final AudioEngine engine = session.audioEngine;
    return Material(
      elevation: 8,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: StreamBuilder<Duration>(
            stream: engine.positionStream,
            builder: (BuildContext context, AsyncSnapshot<Duration> snapshot) {
              final Duration position = snapshot.data ?? engine.position;
              final Duration total = engine.duration ?? position;
              final double maxMs = total.inMilliseconds.toDouble();
              final double max = maxMs <= 0 ? 1 : maxMs;
              final double value = position.inMilliseconds.clamp(0, max).toDouble();
              return Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        InkWell(
                          onTap: onOpenNowPlaying,
                          child: Text(
                            session.currentSong?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Slider(
                          value: value,
                          max: max,
                          onChanged: (double next) {
                            onSeek(Duration(milliseconds: next.round()));
                          },
                        ),
                        Text('${_clock(position)} / ${_clock(total)}'),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onCycleMode,
                    tooltip: _playbackModeLabel(engine),
                    icon: Icon(_playbackModeIcon(engine)),
                  ),
                  IconButton(
                    onPressed: onSkipPrevious,
                    tooltip: '上一首',
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton(
                    onPressed: onToggle,
                    tooltip: engine.playing ? '暂停' : '播放',
                    icon: Icon(engine.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    onPressed: onSkipNext,
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CoverMark extends StatelessWidget {
  const _CoverMark({required this.album, this.size = 40});

  final Album album;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String? path = album.coverPath;
    if (path != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    final String title = album.title;
    if (title.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: const DecoratedBox(
          decoration: BoxDecoration(color: Color(0xFFE0E0E0)),
          child: Icon(Icons.album_outlined),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: Text(
            title.substring(0, 1),
            style: TextStyle(fontSize: size * 0.4),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingPage extends StatefulWidget {
  const _NowPlayingPage({
    required this.session,
    required this.onChanged,
  });

  final LibrarySession session;
  final VoidCallback onChanged;

  @override
  State<_NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<_NowPlayingPage> {
  LibrarySession get session => widget.session;

  Future<void> _refresh(Future<void> Function() action) async {
    await action();
    if (!mounted) {
      return;
    }
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final Song? song = session.currentSong;
    if (song == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final LibraryProjection library = session.library;
    final Album album = library.albumOf(song);
    final String? lyrics = song.lyrics;
    final bool showLyrics = lyrics != null && lyrics.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('正在播放')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: <Widget>[
            _CoverMark(album: album, size: 200),
            const SizedBox(height: 16),
            Text(
              song.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('${library.artistOf(song).name} · ${album.title}'),
            if (showLyrics) ...<Widget>[
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(lyrics),
                  ),
                ),
              ),
            ] else
              const Spacer(),
          ],
        ),
      ),
      bottomNavigationBar: _PlaybackBar(
        session: session,
        onToggle: () {
          if (session.audioEngine.playing) {
            _refresh(session.pause);
          } else {
            _refresh(session.play);
          }
        },
        onSeek: session.seek,
        onSkipNext: () {
          _refresh(session.skipToNext);
        },
        onSkipPrevious: () {
          _refresh(session.skipToPrevious);
        },
        onCycleMode: () {
          _refresh(session.cyclePlaybackMode);
        },
        onOpenNowPlaying: () {},
      ),
    );
  }
}

final class _SongDraft {
  const _SongDraft({
    required this.title,
    required this.artistName,
    required this.albumTitle,
  });

  final String title;
  final String artistName;
  final String albumTitle;
}

class _EditSongDialog extends StatefulWidget {
  const _EditSongDialog({
    required this.title,
    required this.artistName,
    required this.albumTitle,
  });

  final String title;
  final String artistName;
  final String albumTitle;

  @override
  State<_EditSongDialog> createState() => _EditSongDialogState();
}

class _EditSongDialogState extends State<_EditSongDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artistName;
  late final TextEditingController _albumTitle;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.title);
    _artistName = TextEditingController(text: widget.artistName);
    _albumTitle = TextEditingController(text: widget.albumTitle);
  }

  @override
  void dispose() {
    _title.dispose();
    _artistName.dispose();
    _albumTitle.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop(
      _SongDraft(
        title: _title.text,
        artistName: _artistName.text,
        albumTitle: _albumTitle.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '标题'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: _artistName,
            decoration: const InputDecoration(labelText: '主歌手'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: _albumTitle,
            decoration: const InputDecoration(labelText: '专辑名'),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

String _songSubtitle(Song song, LibraryProjection projection) {
  final String artistAlbum =
      '${projection.artistOf(song).name} · ${projection.albumOf(song).title}';
  final int? track = song.trackNumber;
  final String base = track == null ? artistAlbum : '$track · $artistAlbum';
  if (song.needsNetwork) {
    return '$base · 需联网';
  }
  return base;
}

String _clock(Duration duration) {
  final int minutes = duration.inMinutes;
  final int seconds = duration.inSeconds.remainder(60);
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _playbackModeLabel(AudioEngine engine) {
  if (engine.shuffleEnabled) {
    return '随机';
  }
  if (engine.repeatMode == RepeatMode.one) {
    return '单曲循环';
  }
  return '列表循环';
}

IconData _playbackModeIcon(AudioEngine engine) {
  if (engine.shuffleEnabled) {
    return Icons.shuffle;
  }
  if (engine.repeatMode == RepeatMode.one) {
    return Icons.repeat_one;
  }
  return Icons.repeat;
}

String _authMessage(AuthException error) {
  return switch (error.code) {
    'AUTH_USERNAME_TAKEN' => '用户名已被占用',
    'AUTH_INVALID_CREDENTIALS' => '用户名或密码错误',
    'AUTH_INVALID_TOKEN' => '登录已失效，请重新登录',
    _ => '请求失败',
  };
}
