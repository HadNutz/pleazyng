part of 'music_car_host.dart';

class _CarVideoSession {
  _CarVideoSession(
    this.id,
    this.client,
    this.item,
    this.serverSession,
    this.mediaSource,
    this.timeline,
    this.offset,
    this.position,
    this.authorized,
  );
  String id;
  final MediaServerClient client;
  final MediaItem item;
  final String? serverSession;
  final String? mediaSource;
  MediaPartTimeline? timeline;
  int offset;
  int position;
  final bool Function() authorized;
  bool reported = false;
  Duration get time => Duration(milliseconds: position);
  Duration get duration => timeline?.duration ?? Duration(milliseconds: item.durationMs ?? 0);
}

extension _CarVideo on _MusicCarHostState {
  bool _visibleVideo(MediaItem item, MediaServerClient client) {
    if (!_current ||
        item.backend != client.backend ||
        item.serverId != client.serverId.value ||
        item.libraryId == null ||
        (item.kind != MediaKind.movie && item.kind != MediaKind.episode)) {
      return false;
    }
    final hidden = context.read<HiddenLibrariesProvider>();
    return hidden.isInitialized &&
        !hidden.isLibraryHidden('${item.serverId}:${item.libraryId}') &&
        context.read<LibrariesProvider>().libraries.any(
          (l) => l.backend == item.backend && l.serverId == item.serverId && l.id == item.libraryId && !l.hidden,
        );
  }

  Future<List<Map<String, Object?>>> _carVideoRows() async {
    if (!_connected || !_videoCapable) return [];
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !_current || !_connected) return [];
    final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients.values.toList();
    final batches = await Future.wait(
      clients.map((client) async {
        final current = _readClient(client);
        final excluded = context
            .read<LibrariesProvider>()
            .libraries
            .where((l) => l.serverId == client.serverId.value && (l.hidden || hidden.isLibraryHidden(l.globalKey)))
            .map((l) => l.id)
            .toSet();
        try {
          final items = await client.fetchContinueWatching(count: 20, excludedLibraryIds: excluded);
          if (!current() || !_connected) return <Map<String, Object?>>[];
          return [
            for (final item in items)
              if (_visibleVideo(item, client))
                {..._item(item), 'video': true, 'elapsed': item.viewOffsetMs ?? 0, 'duration': item.durationMs ?? 0},
          ];
        } catch (_) {
          return <Map<String, Object?>>[];
        }
      }),
    );
    return _current && _connected ? batches.expand((b) => b).take(_MusicCarHostState._pageSize).toList() : [];
  }

  Future<bool> _startCarVideo(String id, int intent, Future<bool> Function() commit) async {
    final client = _authorizations[id]?.client, item = _items[id];
    if (client == null || item == null || !_catalogItemCurrent(id) || !_videoCapable || !_visibleVideo(item, client)) {
      return false;
    }
    final actor = _readClient(client);
    bool authorized() => actor() && _visibleVideo(item, client);
    bool current() => intent == _videoIntent && _connected && _videoCapable && authorized();
    final resume = Duration(milliseconds: item.viewOffsetMs ?? 0);
    final target = await client.resolveExternalPlayback(item, position: resume, registerPlayback: false);
    final url = Uri.tryParse(target?.url ?? '');
    if (target == null ||
        url == null ||
        !{'https', 'http'}.contains(url.scheme) ||
        url.host.isEmpty ||
        !current() ||
        !await commit()) {
      return false;
    }
    final coordinator = PlaybackCoordinator.instance;
    await _finishCarVideo();
    if (!current() || !await coordinator.stopVideoAndExit() || !current()) return false;
    await coordinator.claimVideo();
    if (!current()) return false;
    final timeline = target.partTimeline;
    final offset = timeline?.current.start.inMilliseconds ?? 0;
    final start = timeline == null || timeline.covers(resume) ? resume.inMilliseconds - offset : 0;
    final session = _CarVideoSession(
      const Uuid().v4(),
      client,
      item,
      target.playSessionId,
      target.mediaInfo?.mediaSourceId,
      timeline,
      offset,
      start + offset,
      authorized,
    );
    _video = session;
    coordinator.registerVideoSession(
      shutdown: _retireVideo,
      stopAndExit: () async {
        await _stopCarVideo();
        return true;
      },
    );
    try {
      final opened = await _MusicCarHostState._channel.invokeMethod<bool>('openCarVideo', {
        'id': session.id,
        'url': url.toString(),
        'title': item.displayTitle,
        'position': start,
        'offset': offset,
        'duration': session.duration.inMilliseconds,
        'multipart': timeline != null,
      });
      if (opened != true || !current()) {
        await _finishCarVideo();
        return false;
      }
      await client.reportPlaybackStarted(
        itemId: item.id,
        position: session.time,
        duration: session.duration,
        playSessionId: session.serverSession,
      );
      session.reported = true;
      if (!current()) {
        await _finishCarVideo();
        return false;
      }
      return true;
    } catch (_) {
      await _finishCarVideo();
      rethrow;
    }
  }

  Future<void> _stopCarVideo() => _videoCommands.run(_finishCarVideo);

  Future<void> _finishCarVideo() async {
    final session = _video;
    if (session == null) return;
    _video = null;
    PlaybackCoordinator.instance.unregisterVideoSession(_retireVideo);
    try {
      final position = await _MusicCarHostState._channel.invokeMethod<int>('stopCarVideo', session.id);
      if (position != null && position >= 0) session.position = position + session.offset;
    } finally {
      if (session.reported && session.authorized()) {
        await session.client.reportPlaybackStopped(
          itemId: session.item.id,
          position: session.time,
          duration: session.duration,
          playSessionId: session.serverSession,
        );
      }
    }
  }

  Future<bool> _openVideoPosition(_CarVideoSession session, int position, {required bool playing}) async {
    final before = session.timeline;
    if (before == null) return false;
    final time = Duration(milliseconds: position.clamp(0, before.duration.inMilliseconds));
    final expected = before.parts[before.indexAt(time)];
    final intent = _videoIntent;
    bool current() =>
        _connected && _videoCapable && identical(_video, session) && intent == _videoIntent && session.authorized();
    try {
      final target = await session.client.resolveExternalPlayback(
        session.item,
        position: time,
        mediaSourceId: session.mediaSource,
        registerPlayback: false,
      );
      final timeline = target?.partTimeline, url = Uri.tryParse(target?.url ?? '');
      if (!current() ||
          timeline == null ||
          timeline.current.partId != expected.partId ||
          timeline.current.start != expected.start ||
          url == null ||
          !{'https', 'http'}.contains(url.scheme) ||
          url.host.isEmpty) {
        return false;
      }
      session.id = const Uuid().v4();
      session.timeline = timeline;
      session.offset = timeline.current.start.inMilliseconds;
      session.position = time.inMilliseconds;
      return await _MusicCarHostState._channel.invokeMethod<bool>('openCarVideo', {
                'id': session.id,
                'url': url.toString(),
                'title': session.item.displayTitle,
                'position': session.position - session.offset,
                'offset': session.offset,
                'duration': timeline.duration.inMilliseconds,
                'multipart': true,
                'playing': playing,
              }) ==
              true &&
          current();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _carVideoEvent(Map<String, dynamic> args) async {
    final session = _video;
    if (session == null || session.id != args['id']) return false;
    final ms = args['position'];
    if (ms is int && ms >= 0) session.position = ms + session.offset;
    final timeline = session.timeline;
    if (session.authorized() && _connected && timeline != null) {
      final seek = args['seek'];
      final next = seek is int
          ? seek
          : args['reason'] == 'completed' && timeline.hasNext
          ? timeline.current.end.inMilliseconds
          : null;
      if (next != null) {
        if (!await _openVideoPosition(session, next, playing: seek == null || args['paused'] != true)) {
          await _finishCarVideo();
        }
        return true;
      }
    }
    if (args['ended'] == true || !session.authorized() || !_connected) {
      await _finishCarVideo();
      return true;
    }
    if (session.reported) {
      await session.client.reportPlaybackProgress(
        itemId: session.item.id,
        position: session.time,
        duration: session.duration,
        isPaused: args['paused'] == true,
        playSessionId: session.serverSession,
      );
    }
    return true;
  }
}
