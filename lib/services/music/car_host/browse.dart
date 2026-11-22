part of '../music_car_host.dart';

extension _MusicCarBrowse on _MusicCarHostState {
  Future<Uint8List?> _audiobookArtwork(String id, SourceEntry entry, int size) async {
    final sources = _sourceController;
    if (sources == null || _profileId == null || sources.profileId != _profileId || sources.blocked) return null;
    bool current() =>
        _current &&
        _audiobookEntries[id] == entry &&
        sources.profileId == _profileId &&
        !sources.blocked &&
        sources.sources.any((source) => source.id == entry.sourceId && source.profileId == _profileId);
    if (!current()) return null;
    return _carArtwork.load(
      id: jsonEncode([id, entry.coverId, entry.onlinePosterUrl]),
      size: size,
      isCurrent: current,
      read: () async {
        if (!current()) return null;
        final file = await sources.cover(entry);
        if (!current() || file == null) return null;
        try {
          if (await file.length() > MusicCarArtwork.maxInputBytes || !current()) return null;
          return await file.readAsBytes();
        } on Object {
          return null;
        }
      },
    );
  }

  Future<Uint8List?> _artwork(Map<String, dynamic> args) async {
    final id = args['id'], size = args['size'];
    if (id is! String || id.length > 256 || size is! int || size < 32 || size > 256) return null;
    final audiobook = _audiobookEntries[id];
    if (audiobook != null) return _audiobookArtwork(id, audiobook, size);
    final owner = _artworkItems[id];
    if (owner == null) return null;
    final item = owner.item, client = owner.client;
    final downloads = context.read<DownloadProvider?>();
    final hidden = context.read<HiddenLibrariesProvider?>();
    await hidden?.ensureInitialized();
    bool current() {
      if (!_current ||
          _artworkItems[id] != owner ||
          hidden?.isLibraryHidden('${item.serverId}:${item.libraryId}') == true) {
        return false;
      }
      if (id.startsWith('queue:')) {
        final parts = id.split(':');
        final index = parts.length == 4 ? int.tryParse(parts[3]) : null;
        if (parts.length != 4 ||
            parts[1] != _itemScope ||
            int.tryParse(parts[2]) != _catalogRevision ||
            index == null ||
            index < 0 ||
            index >= _music.queue.length ||
            _music.queue[index].globalKey != item.globalKey) {
          return false;
        }
      }
      if (client != null) {
        return client.backend == item.backend &&
            _clientCurrent(client, owner.authentication!) &&
            owner.scope == musicAccountScope(client);
      }
      return context.getMediaClientForItemOrNull(item) == null &&
          downloads?.downloadedTracks.any((row) => row.globalKey == item.globalKey && row.backend == item.backend) ==
              true;
    }

    if (!current()) return null;
    final path = item.thumbPath ?? item.parentThumbPath ?? item.grandparentThumbPath;
    if (path == null || path.isEmpty || item.serverId == null) return null;
    return _carArtwork.load(
      id: jsonEncode([id, owner.scope, path]),
      size: size,
      isCurrent: current,
      read: () async {
        if (!current()) return null;
        final local = downloads?.getArtworkLocalPath(ServerId(item.serverId!), path);
        if (local != null && await File(local).exists()) {
          if (!current()) return null;
          final builder = BytesBuilder(copy: false);
          await for (final chunk in File(local).openRead(0, MusicCarArtwork.maxInputBytes + 1)) {
            if (!current()) return null;
            builder.add(chunk);
            if (builder.length > MusicCarArtwork.maxInputBytes) return null;
          }
          return builder.takeBytes();
        }
        if (!current() || client == null || client.isOfflineMode) return null;
        final url = client.thumbnailUrl(path, width: size, height: size);
        if (url.isEmpty) return null;
        return _artworkHttp.getBytes(url, maxBytes: MusicCarArtwork.maxInputBytes, timeout: const Duration(seconds: 6));
      },
    );
  }

  bool _catalogItemCurrent(String id) {
    final owner = _authorizations[id];
    if (!_current || owner == null || owner.generation != _profiles.identityMutationGeneration) return false;
    final client = owner.client, item = _items[id];
    if (item != null && _hiddenCarLibraries().contains('${item.serverId}:${item.libraryId}')) return false;
    if (!_offlineRows.contains(id) &&
        client != null &&
        !client.isOfflineMode &&
        item?.libraryId != null &&
        item!.kind != MediaKind.playlist) {
      final libraries = context.read<LibrariesProvider?>();
      if (libraries != null &&
          (libraries.isDisposed ||
              !libraries.libraries.any(
                (library) =>
                    library.serverId == item.serverId &&
                    library.id == item.libraryId &&
                    library.backend == item.backend &&
                    !library.hidden,
              ))) {
        return false;
      }
    }
    return client == null ||
        _clientCurrent(client, owner.authentication!) && owner.account == musicAccountScope(client);
  }

  Future<List<Map<String, Object?>>> _serverRadioRows({String? libraryKey}) async {
    final generation = _profiles.identityMutationGeneration;
    final hidden = context.read<HiddenLibrariesProvider>();
    final libraries = context.read<LibrariesProvider>();
    final manager = context.read<MultiServerProvider>().serverManager;
    bool current() =>
        _current && generation == _profiles.identityMutationGeneration && !libraries.isDisposed && !hidden.isDisposed;
    await hidden.ensureInitialized();
    if (!current()) return [];
    // Capture all original owners before the first catalog request.
    final sources =
        [
              for (final library in libraries.libraries)
                if (library.kind == MediaKind.artist &&
                    library.serverId != null &&
                    !library.hidden &&
                    (libraryKey == null || libraryKey == library.globalKey) &&
                    !hidden.hiddenLibraryKeys.contains(library.globalKey))
                  (library, manager.getClient(ServerId(library.serverId!))),
            ]
            .where(
              (source) =>
                  source.$2 is ServerMusicRadioClient &&
                  manager.isServerVisible(source.$2!.serverId) &&
                  manager.isClientOnline(source.$2!.serverId),
            )
            .take(16)
            .map((source) => (source.$1, source.$2!, _readClient(source.$2!)))
            .toList();
    final rows = <Map<String, Object?>>[];
    for (var start = 0; start < sources.length; start += 4) {
      final batches = await Future.wait(
        sources.skip(start).take(4).map((source) async {
          final (library, client, ownerCurrent) = source;
          final radioClient = client as ServerMusicRadioClient;
          bool visible() =>
              current() &&
              ownerCurrent() &&
              !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
              libraries.libraries.any((row) => row.globalKey == library.globalKey && !row.hidden);
          if (!visible()) return <Map<String, Object?>>[];
          final catalog = await radioClient.serverMusicRadios(library.id).timeout(const Duration(seconds: 10));
          if (!visible()) return <Map<String, Object?>>[];
          final result = <Map<String, Object?>>[], seen = <String>{};
          for (final radio in catalog.take(32)) {
            if (!radio.valid ||
                radio.serverId != client.serverId.value ||
                radio.libraryId != library.id ||
                !radioClient.serverMusicRadioCurrent(radio) ||
                !seen.add(radio.key)) {
              continue;
            }
            final id = 'serverRadio:$_itemScope:${++_itemSequence}';
            if (_serverRadios.length >= 512) _serverRadios.remove(_serverRadios.keys.first);
            _serverRadios[id] = (
              radio: radio,
              client: client,
              current: () => visible() && radioClient.serverMusicRadioCurrent(radio),
            );
            result.add({
              'id': id,
              'title': radio.title,
              'subtitle': [library.title, radio.familyTitle].whereType<String>().join(' · '),
              'kind': 'station',
              'playable': true,
            });
          }
          return result;
        }),
      );
      if (!current()) return [];
      for (final batch in batches) {
        rows.addAll(batch);
      }
    }
    return rows;
  }

  Future<List<Map<String, Object?>>> _stationPins() async {
    if (_profileId == null) return [];
    final store = MusicLibraryStore(context.read<AppDatabase>(), _profileId);
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    final rows = await store.documents('carStationPin');
    final result = <Map<String, Object?>>[];
    for (final pin in rows) {
      if (!_current) return [];
      final id = pin['id'];
      if (id is! String || pin['account'] is! String) continue;
      final doc = await store.document('station', id);
      if (!mounted || !_current) return [];
      if (doc == null) continue;
      final station = MusicStation.fromJson(doc);
      if (hidden.isLibraryHidden('${station.serverId}:${station.libraryId}')) continue;
      final manager = context.read<MultiServerProvider>().serverManager;
      final server = ServerId(station.serverId), client = manager.getClient(ServerId(station.serverId));
      if (client != null && (musicAccountScope(client) != pin['account'] || !manager.isServerVisible(server))) continue;
      final online = client != null && manager.isClientOnline(server) && !client.isOfflineMode;
      if (!online) {
        final snapshot = await store.document('stationSnapshot', id);
        if (!_current || snapshot?['accountScope'] != pin['account']) continue;
        if (musicSnapshotTracks(snapshot, await _visibleDownloads(), accountScope: pin['account'] as String).isEmpty) {
          continue;
        }
      }
      if (!_current) return [];
      result.add({'id': '${online ? 'station' : 'offlineStation'}:$id', 'title': station.title, 'playable': true});
      if (result.length == 4) break;
    }
    return result;
  }

  Future<List<Map<String, Object?>>> _browse(String id) async {
    var manifestStart = 0, ordinal = 0;
    String? manifestRevision;
    if (id.startsWith('playlistPage:')) {
      final cursor = jsonDecode(utf8.decode(base64Url.decode(id.substring(13)))) as List;
      if (cursor.length != 5 || cursor[4] != _downloadGeneration) return [];
      id = cursor[0] as String;
      manifestStart = cursor[1] as int;
      ordinal = cursor[2] as int;
      manifestRevision = cursor[3] as String;
    }
    var offset = 0;
    if (id.startsWith('page:')) {
      final parts = id.split(':');
      if (parts.length != 3) throw PlatformException(code: 'invalid_page');
      offset = int.tryParse(parts[1]) ?? -1;
      if (offset < 0 || offset > 1000000) throw PlatformException(code: 'invalid_page');
      try {
        id = utf8.decode(base64Url.decode(parts[2]));
      } on FormatException {
        throw PlatformException(code: 'invalid_page');
      }
    }
    final sources = _sourceController;
    final hasSpoken = sources != null && !sources.blocked && sources.profileId == _profileId;
    if (id.startsWith('spokenOptions:')) {
      final target = id.substring('spokenOptions:'.length);
      final queued = target.startsWith('spokenQueue:$_itemScope:');
      if (!queued && !_audiobookEntries.containsKey(target)) return [];
      return [
        for (final action in {
          'play': t.universalMedia.playNow,
          if (queued) 'remove': t.musicExperience.remove,
          if (!queued) 'next': t.music.playNext,
          if (!queued) 'later': t.music.addToQueue,
        }.entries)
          {'id': 'spokenAction:${action.key}:$target', 'playable': true, 'title': action.value},
      ];
    }
    if (id == 'root') {
      return [
        _folder('home', t.common.home),
        _folder('music', t.musicTools.home),
        if (hasSpoken) _folder('spoken', '${t.fileSources.audiobooks} · ${t.podcasts.title}'),
        _folder('downloads', t.navigation.downloads),
      ];
    }
    if (id == 'carEmpty') return [];
    if (id == 'rootPlayable') {
      final owned = await _visibleDownloads();
      if (!_current) return [];
      return [
        if (_music.currentTrack != null || _spoken != null)
          {'id': 'resume', 'title': t.common.resume, 'playable': true},
        if (owned.isNotEmpty)
          {
            'id': 'downloadMix:$_itemScope',
            'title': '${t.common.shuffle} · ${t.navigation.downloads}',
            'playable': true,
          },
        for (final track in owned.take(4)) _item(track, offline: true),
      ];
    }
    if (id == 'rating' && _ratingState?.kind == 'rating') {
      final state = _ratingState!;
      return [
        for (var score = 5; score >= 1; score--)
          {
            'id': 'score:$_itemScope:$_catalogRevision:${score * 2}',
            'title': '★' * score,
            'subtitle': state.value == score * 2 ? t.discover.rating : null,
            'playable': true,
            'quiet': true,
          },
        {'id': 'score:$_itemScope:$_catalogRevision:-1', 'title': t.common.clear, 'playable': true, 'quiet': true},
        if (state.canUndo)
          {
            'id': 'score:$_itemScope:$_catalogRevision:undo',
            'title': t.discover.findNext.undo,
            'playable': true,
            'quiet': true,
          },
      ];
    }
    if (id == 'continueCarVideo') return _carVideoRows();
    if (id == 'home') {
      final pins = await context.read<MusicExperience?>()?.pins.load();
      if (!_current) return [];
      final stationPins = await _stationPins();
      if (!_current) return [];
      final resume = hasSpoken
          ? (await _browse('continueAudiobooks')).where((r) => r['playable'] == true).firstOrNull
          : null;
      if (!mounted || !_current) return [];
      return [
        if (_spoken != null || _music.currentTrack != null)
          {
            'id': 'resume',
            'title': t.common.resume,
            'subtitle': _spoken?.entry?.displayTitle ?? _music.currentTrack?.displayTitle,
            'playable': true,
          },
        if (resume != null && resume['title'] != _spoken?.entry?.displayTitle) {...resume, 'quickResume': true},
        if (pins != null)
          for (final pin in pins.take(4)) {..._item(pin.item), 'playable': true},
        if (_videoCapable) _folder('continueCarVideo', t.fileSources.continueWatching),
        _folder('queue', t.music.queue),
        if (Platform.isAndroid && _ratingState?.kind == 'rating') _folder('rating', t.mediaMenu.rate),
        ...stationPins,
        if ((_connected || PlatformDetector.isAutomotiveMedia()) &&
            _music.currentTrack != null &&
            context.read<GuestJukebox?>() != null)
          _folder('guest', t.livingRoom.jukebox),
        _folder('pins', t.musicTools.pins),
        _folder('favorites', t.libraries.filterCategories.favorites),
        _folder('recent', t.musicTools.recent),
        _folder('stations', t.musicTools.stations),
      ];
    }
    if (id == 'favorites') {
      final selection = await loadProfileMusicFavorites(context);
      return _current ? _page(selection.tracks.map(_item), id, offset) : [];
    }
    if (id == 'pins') {
      final pins = await context.read<MusicExperience?>()?.pins.load();
      return _current && pins != null ? _page(pins.map((pin) => _item(pin.item)), id, offset) : [];
    }
    if (id == 'spoken') {
      return [
        _folder('continueAudiobooks', t.fileSources.continueListening),
        if (_spoken?.chapters.isNotEmpty == true) _folder('chapters', t.fileSources.chapters),
        if (_spoken != null) _folder('bookmarks', t.fileSources.bookmarks),
        _folder('audiobooks', t.fileSources.audiobooks),
        _folder('spokenQueue', t.music.upNext),
        _folder('unplayedEpisodes', t.libraries.filterCategories.unplayed),
        _folder('startedEpisodes', t.discover.findNext.inProgress),
        _folder('episodes', t.podcasts.episodes),
        _folder('subscriptions', t.podcasts.shows),
        _folder('downloadEpisodes', t.navigation.downloads),
      ];
    }
    if (id == 'spokenControls') {
      return [
        _folder('spokenQueue', t.music.upNext),
        if (_spoken?.chapters.isNotEmpty == true) _folder('chapters', t.fileSources.chapters),
        if (_spoken != null) _folder('bookmarks', t.fileSources.bookmarks),
      ];
    }
    if (id == 'spokenQueue' && hasSpoken) {
      final queued = await context.read<SourcePlayback?>()?.spokenQueue();
      if (!_current || queued == null) return [];
      return _page(
        queued.map(
          (r) => {
            'id': 'spokenQueue:$_itemScope:${r.id}',
            'queuedSpoken': true,
            'title': r.item.displayTitle,
            'subtitle': r.item.series,
            'playable': true,
          },
        ),
        id,
        offset,
      );
    }
    if (id == 'bookmarks') {
      final spoken = _spoken, entry = spoken?.entry, revision = _catalogRevision;
      if (!hasSpoken || entry == null || spoken?.progress == null) return [];
      final notes = await sources.repository.annotations(_profileId!, entry.key);
      if (!_current || _spoken?.entry?.key != entry.key || revision != _catalogRevision) return [];
      return _page(
        notes
            .where(
              (note) =>
                  note.mode == PublicationMode.listening &&
                  note.edition == spoken!.progress?.edition &&
                  note.positionMs != null,
            )
            .map((note) {
              final timestamp = formatDurationTimestamp(Duration(milliseconds: note.positionMs!));
              return {
                'id': 'bookmark:$_itemScope:$revision:${note.id}',
                'title': note.note.isEmpty ? timestamp : note.note,
                'subtitle': note.note.isEmpty ? null : timestamp,
                'playable': true,
              };
            }),
        id,
        offset,
      );
    }
    if (id == 'chapters') {
      final chapters = _spoken?.chapters ?? [];
      return _page(
        [
          for (final (i, ch) in chapters.indexed)
            {'id': 'chapter:$_itemScope:$_catalogRevision:$i', 'title': ch.title, 'playable': true},
        ],
        id,
        offset,
      );
    }
    if (id == 'downloads') {
      return [
        {'id': 'downloadMix:$_itemScope', 'title': '${t.common.shuffle} · ${t.navigation.downloads}', 'playable': true},
        _folder('offline', t.libraries.groupings.tracks),
        _folder('offlineChart', t.discover.mostPlayedIn(library: t.navigation.downloads)),
        _folder('offlineAlbums', t.libraries.groupings.albums),
        _folder('offlinePlaylists', t.common.mediaKind.playlist),
        _folder('offlineArtists', t.libraries.groupings.artists),
        _folder('offlineStations', t.musicTools.stations),
        if (hasSpoken) ...[
          _folder('downloadBooks', t.fileSources.audiobooks),
          _folder('downloadEpisodes', t.podcasts.title),
        ],
      ];
    }
    if (id == 'offlineChart' || id.startsWith('offlineChart:')) {
      final owned = await _visibleDownloads();
      if (!mounted || !_current) return [];
      final libraries = {for (final l in context.read<LibrariesProvider>().libraries) l.globalKey: l.title};
      String library(MediaItem track) => '${track.serverId}:${track.libraryId}';
      if (id == 'offlineChart') {
        final keys = owned.map(library).toSet().toList()..sort();
        return _page(
          keys.map(
            (k) => _folder(
              'offlineChart:$k',
              libraries[k] ??
                  owned.where((track) => library(track) == k).firstOrNull?.libraryTitle ??
                  t.navigation.downloads,
            ),
          ),
          id,
          offset,
        );
      }
      final tracks = {
        for (final item in owned.where((e) => library(e) == id.substring('offlineChart:'.length))) item.globalKey: item,
      };
      final keys = await MusicLibraryStore(context.read<AppDatabase>(), _profileId!).rankDownloaded(tracks.keys);
      if (!mounted || !_current) return [];
      return _page(keys.map((k) => _item(tracks[k]!, offline: true)), id, offset);
    }
    if (id == 'offlinePlaylists') {
      final store = MusicLibraryStore(context.read<AppDatabase>(), _profileId!);
      final docs = await store.documents('offlinePlaylist', limit: _MusicCarHostState._pageSize, offset: offset);
      if (!mounted || !_current) return [];
      final downloads = await _visibleDownloads();
      if (!mounted || !_current) return [];
      final rows = <Map<String, Object?>>[];
      for (final doc in docs) {
        final metadata = doc['playlist'];
        if (metadata is! Map<String, dynamic>) continue;
        final playlist = MediaItem.fromJson(metadata);
        final client = context.getMediaClientForItemOrNull(playlist);
        if (client != null && musicAccountScope(client) != doc['accountScope']) continue;
        final tracks = await store.ownedPlaylistTracks(
          playlist,
          downloads,
          client == null ? null : musicAccountScope(client),
          firstOnly: true,
        );
        if (!mounted || !_current) return [];
        if (tracks.isEmpty) continue;
        final row = _item(playlist, offline: true);
        rows.add(row);
      }
      if (docs.length == _MusicCarHostState._pageSize) rows.add(_nextPage(id, offset + docs.length));
      return rows;
    }
    if (id == 'offlineAlbums' || id == 'offlineArtists') {
      final tracks = await _visibleDownloads();
      if (!_current) return [];
      return _page(_offlineGroups(tracks, albums: id == 'offlineAlbums'), id, offset);
    }
    if (id == 'subscriptions' && hasSpoken) {
      final epoch = sources.generation;
      final shows = await sources.repository.podcastShows(
        _profileId!,
        offset: offset,
        limit: _MusicCarHostState._pageSize,
      );
      if (!_current || !sources.current(epoch)) return [];
      return [
        for (final show in shows)
          if (sources.sources.where((s) => s.id == show.source).firstOrNull case final source?)
            _folder(
              'show:$_itemScope:${base64Url.encode(utf8.encode(jsonEncode([show.source, show.parent])))}',
              show.title.isEmpty ? source.name : show.title,
            ),
        if (shows.length == _MusicCarHostState._pageSize) _nextPage(id, offset + shows.length),
      ];
    }
    if (['episodes', 'downloadEpisodes', 'unplayedEpisodes', 'startedEpisodes'].contains(id) ||
        id.startsWith('feed:') ||
        id.startsWith('show:$_itemScope:')) {
      if (!hasSpoken) return [];
      final show = id.startsWith('show:')
          ? jsonDecode(utf8.decode(base64Url.decode(id.split(':').last))) as List
          : null;
      final source = show != null
          ? show[0] as String
          : id.startsWith('feed:')
          ? id.substring(5)
          : null;
      final epoch = sources.generation;
      if (source != null && !sources.sources.any((s) => s.id == source)) return [];
      final batch = await sources.repository.podcastEntries(
        _profileId!,
        source: source,
        parent: show != null && show[1] != '' ? show[1] as String : null,
        unplayedOnly: id == 'unplayedEpisodes',
        inProgressOnly: id == 'startedEpisodes',
        downloadedOnly: id == 'downloadEpisodes',
        offset: offset,
        limit: _MusicCarHostState._pageSize,
      );
      if (!_current || !sources.current(epoch)) return [];
      final verified = id == 'downloadEpisodes' ? await sources.downloads.verifiedFiles(_profileId, batch) : null;
      if (!_current || !sources.current(epoch)) return [];
      return [
        for (final e in batch)
          if (_isEpisode(e) &&
              e.audio.isNotEmpty &&
              sources.sources.any((s) => s.id == e.sourceId) &&
              (verified == null ? !e.unavailable : PublicationOfflineReadiness.evaluate(e, verified).canListen))
            _audiobookItem(e, offline: verified != null),
        if (batch.length == _MusicCarHostState._pageSize) _nextPage(id, offset + batch.length),
      ];
    }
    if (id == 'music') {
      return [
        _folder('libraries', t.navigation.libraries),
        _folder('playlists', t.common.mediaKind.playlist),
        _folder('recipes', t.musicExperience.saved),
        _folder('stations', t.musicTools.stations),
        if (context.read<MultiServerProvider?>()?.serverManager.visibleOnlineClients.values.any(
              (client) => client is ServerMusicRadioClient,
            ) ==
            true)
          _folder('serverRadio', t.libraries.tabs.recommended),
        _folder('recent', t.musicTools.recent),
      ];
    }
    if (id == 'continueAudiobooks') {
      final sources = _sourceController;
      if (sources == null || sources.blocked || _profileId == null || sources.profileId != _profileId) return [];
      final recent = await sources.repository.recentProgressEntries(_profileId, limit: 100);
      if (!mounted || !_current || sources.profileId != _profileId || sources.blocked) return [];
      final configured = sources.sources.map((source) => source.id).toSet();
      final seen = <String>{};
      final entries = recent
          .where((row) => row.$2.mode == PublicationMode.listening && !row.$2.finished)
          .where(
            (row) =>
                _isSpoken(row.$1) &&
                row.$1.audio.isNotEmpty &&
                !row.$1.unavailable &&
                configured.contains(row.$1.sourceId) &&
                seen.add(row.$1.key),
          )
          .map((row) {
            final entry = row.$1, position = row.$2.positionMs;
            final chapter = entry.chapters.where((c) => c.startMs <= position && c.endMs > position).firstOrNull;
            final duration = entry.audio.every((f) => (f.durationMs ?? 0) > 0)
                ? entry.audio.fold<int>(0, (sum, f) => sum + f.durationMs!)
                : 0;
            final detail = [
              if (chapter != null) chapter.title,
              if (duration > position)
                t.fileSources.remaining(time: formatDurationTimestamp(Duration(milliseconds: duration - position))),
            ];
            return {
              ..._audiobookItem(entry),
              'quickResume': true,
              if (detail.isNotEmpty) 'subtitle': detail.join(' · '),
            };
          });
      return _page(entries, id, offset);
    }
    if (id == 'audiobooks' ||
        id == 'downloadBooks' ||
        id.startsWith('audiobookPage:') ||
        id.startsWith('downloadBookPage:')) {
      final sources = _sourceController;
      if (sources == null || sources.blocked || _profileId == null || sources.profileId != _profileId) return [];
      String? cursor;
      final offline = id == 'downloadBooks' || id.startsWith('downloadBookPage:');
      final epoch = sources.generation;
      if (id.contains(':')) {
        final value = id.split(':').last;
        if (!RegExp(r'^\d{1,12}$').hasMatch(value)) throw PlatformException(code: 'invalid_audiobook_page');
        cursor = value;
      }
      final page = await sources.repository.entriesPage(
        _profileId,
        shelf: PublicationShelf.audiobooks,
        downloadedOnly: offline,
        cursor: cursor,
        limit: _MusicCarHostState._pageSize,
      );
      if (!mounted || !_current || sources.profileId != _profileId || sources.blocked) return [];
      final verified = offline ? await sources.downloads.verifiedFiles(_profileId, page.items) : null;
      if (!_current || !sources.current(epoch)) return [];
      final configured = sources.sources.map((source) => source.id).toSet();
      final rows = <Map<String, Object?>>[
        for (final entry in page.items)
          if (entry.kind == SourceItemKind.audiobook &&
              entry.audio.isNotEmpty &&
              (verified == null
                  ? !entry.unavailable
                  : PublicationOfflineReadiness.evaluate(entry, verified).canListen) &&
              configured.contains(entry.sourceId))
            _audiobookItem(entry, offline: offline),
        if (page.cursor case final cursor?)
          _folder(offline ? 'downloadBookPage:$cursor' : 'audiobookPage:$cursor', t.fileSources.loadMore),
      ];
      return rows;
    }
    if (id == 'queue') {
      final queue = _music.queue;
      final start = _music.currentIndex.clamp(0, queue.length);
      return [
        for (var i = start + offset; i < queue.length && i < start + offset + _MusicCarHostState._pageSize; i++)
          _queueItem(queue[i], i),
        if (start + offset + _MusicCarHostState._pageSize < queue.length)
          _nextPage(id, offset + _MusicCarHostState._pageSize),
      ];
    }
    if (id == 'playlists') {
      final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients.values;
      return _page(
        clients.map(
          (client) => _folder('playlists:${client.serverId.value}', client.serverName ?? client.serverId.value),
        ),
        id,
        offset,
      );
    }
    if (id.startsWith('playlists:')) {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(id.substring(10)));
      if (client == null) return [];
      final current = _readClient(client);
      final page = await client.fetchPlaylistsPage(
        playlistType: 'audio',
        start: offset,
        size: _MusicCarHostState._pageSize,
      );
      if (!current()) return [];
      return [
        ...page.items
            .where(
              (p) =>
                  p.playlistType == 'audio' &&
                  p.backend == client.backend &&
                  p.id.isNotEmpty &&
                  (p.serverId == null || p.serverId == client.serverId.value),
            )
            .map(
              (p) => _item(
                MediaItem.fromJson({
                  'backend': p.backend.name,
                  'id': p.id,
                  'kind': 'playlist',
                  'title': p.title,
                  'serverId': client.serverId.value,
                  'thumbPath': p.displayImagePath,
                }),
              ),
            ),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    if (id == 'offline') {
      final owned = await _visibleDownloads();
      if (!_current) return [];
      return owned.isEmpty
          ? [_folder('carEmpty', t.downloads.noDownloads)]
          : _page(owned.map((e) => _item(e, offline: true)), id, offset);
    }
    if (id == 'recent') {
      final rows = await MusicLibraryStore(context.read<AppDatabase>(), _profileId!).recent(limit: 100);
      return _current ? _page(rows.map(_item), id, offset) : [];
    }
    if (id == 'stations' || id == 'offlineStations') {
      final rows = await MusicLibraryStore(context.read<AppDatabase>(), _profileId!).documents('station', limit: 100);
      if (!mounted || !_current) return [];
      if (id == 'offlineStations') {
        final store = MusicLibraryStore(context.read<AppDatabase>(), _profileId);
        final owned = await _visibleDownloads();
        if (!_current) return [];
        final saved = <Map<String, Object?>>[];
        for (final row in rows) {
          final station = MusicStation.fromJson(row);
          final snapshot = await store.document('stationSnapshot', station.id);
          if (!mounted || !_current) return [];
          final client = context.read<MultiServerProvider?>()?.getClientForServer(ServerId(station.serverId));
          if (musicSnapshotTracks(
            snapshot,
            owned,
            accountScope: client == null ? null : musicAccountScope(client),
          ).isNotEmpty) {
            saved.add({'id': 'offlineStation:${station.id}', 'title': station.title, 'playable': true});
          }
        }
        return _page(saved, id, offset);
      }
      return _page(
        rows
            .where((row) => row['id'] is String && row['title'] is String)
            .map((row) => {'id': 'station:${row['id']}', 'title': row['title'], 'playable': true}),
        id,
        offset,
      );
    }
    if (id == 'recipes') {
      final recipes = await MusicRecipeStore(context.read<AppDatabase>(), _profileId!).load();
      if (!mounted || !_current) return [];
      return _page(
        recipes.map((recipe) => {'id': 'recipe:${recipe.id}', 'title': recipe.title, 'playable': true}),
        id,
        offset,
      );
    }
    final hidden = context.read<HiddenLibrariesProvider>();
    await hidden.ensureInitialized();
    if (!mounted || !_current) return [];
    final libraryProvider = context.read<LibrariesProvider>();
    final libraries = libraryProvider.libraries.where(
      (library) =>
          library.kind == MediaKind.artist &&
          library.serverId != null &&
          !library.hidden &&
          !hidden.hiddenLibraryKeys.contains(library.globalKey),
    );
    if (id == 'guest' || id.startsWith('guestNetwork:$_itemScope:')) {
      final room = context.read<GuestJukebox?>();
      if (!_connected || room == null || _music.currentTrack == null) return [];
      if (room.link != null) {
        return [
          {
            'id': 'guestInvite',
            'title': t.livingRoom.jukebox,
            'subtitle': room.library?.title,
            'guest': 'invite',
            'scope': _itemScope,
          },
          {'id': 'guestClose', 'title': t.common.close, 'guest': 'close', 'scope': _itemScope},
        ];
      }
      final manager = context.read<MultiServerProvider>().serverManager;
      final choices = libraries.where(
        (l) =>
            l.serverId != null &&
            manager.isClientOnline(ServerId(l.serverId!)) &&
            manager.isServerVisible(ServerId(l.serverId!)),
      );
      if (id == 'guest' && Platform.isAndroid && (_connected || PlatformDetector.isAutomotiveMedia())) {
        return [
          {
            'id': 'guestPhone:$_itemScope',
            'title': PlatformDetector.isAutomotiveMedia() ? t.livingRoom.jukebox : t.bonusExtras.sendToPhone,
            'subtitle': t.livingRoom.jukeboxInfo,
            'playable': true,
          },
        ];
      }
      if (id == 'guest') {
        return _page(choices.map((l) => _folder('guestNetwork:$_itemScope:${l.globalKey}', l.title)), id, offset);
      }
      final library = choices.where((l) => id == 'guestNetwork:$_itemScope:${l.globalKey}').firstOrNull;
      if (library == null) return [];
      final networks = await KaraokeRoomServer.addresses();
      if (!_current || !_connected) return [];
      return [
        for (final network in networks)
          {
            'id': 'guestOpen',
            'title': network,
            'subtitle': library.title,
            'guest': 'open',
            'scope': _itemScope,
            'library': library.globalKey,
            'network': network,
          },
      ];
    }
    if (id == 'serverRadio') {
      final manager = context.read<MultiServerProvider>().serverManager;
      return _page(
        libraries
            .where(
              (library) =>
                  !library.hidden &&
                  library.serverId != null &&
                  manager.isServerVisible(ServerId(library.serverId!)) &&
                  manager.isClientOnline(ServerId(library.serverId!)) &&
                  manager.getClient(ServerId(library.serverId!)) is ServerMusicRadioClient,
            )
            .map((library) => _folder('radioLibrary:${library.globalKey}', library.title)),
        id,
        offset,
      );
    }
    if (id.startsWith('radioLibrary:')) {
      return _page(await _serverRadioRows(libraryKey: id.substring('offlineChart:'.length)), id, offset);
    }
    if (id == 'libraries') {
      return _page(libraries.map((library) => _folder('library:${library.globalKey}', library.title)), id, offset);
    }
    if (id.startsWith('library:')) {
      final found = libraries.where((library) => 'library:${library.globalKey}' == id);
      if (found.isEmpty) return [];
      final library = found.first;
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(library.serverId!));
      if (client == null || client.backend != library.backend || client.isOfflineMode) return [];
      final ownerCurrent = _readClient(client);
      bool current() =>
          ownerCurrent() &&
          !libraryProvider.isDisposed &&
          !hidden.isDisposed &&
          !hidden.hiddenLibraryKeys.contains(library.globalKey) &&
          libraryProvider.libraries.any(
            (row) => row.globalKey == library.globalKey && row.backend == client.backend && !row.hidden,
          );
      if (!current()) return [];
      final page = await client.fetchLibraryPagedContent(
        library.id,
        query: LibraryQuery(
          kind: MediaKind.artist,
          limit: _MusicCarHostState._pageSize,
          offset: offset,
          sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
        ),
      );
      if (!current()) return [];
      if (page.offset != offset ||
          page.items.length > _MusicCarHostState._pageSize ||
          page.totalCount < offset + page.items.length ||
          page.items.isEmpty && page.totalCount > offset) {
        throw const FormatException('Invalid music car artist page');
      }
      return [
        ...page.items
            .where(
              (row) =>
                  row.kind == MediaKind.artist &&
                  row.id.isNotEmpty &&
                  row.backend == client.backend &&
                  row.serverId == library.serverId &&
                  (row.libraryId == library.id || row.libraryId == null && client.backend.usesMediaBrowserApi),
            )
            // MediaBrowser artist DTOs omit library identity. This request
            // explicitly selected the visible library, so retain that context.
            .map((row) => _item(row.libraryId == null ? row.copyWith(libraryId: library.id) : row)),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final item = _items[id];
    if (item == null) return [];
    if (_offlineRows.contains(id)) {
      if (_profileId == null || !_catalogItemCurrent(id)) return [];
      final client = _authorizations[id]?.client;
      final store = MusicLibraryStore(context.read<AppDatabase>(), _profileId);
      if (item.kind == MediaKind.playlist) {
        final generation = _downloadGeneration;
        final key = (item.backend.name, item.serverId);
        final cached = _ownedByServer[key];
        final owned =
            cached ??
            {
              for (final track in await _visibleDownloads())
                if (track.backend == item.backend && track.serverId == item.serverId) track.id: track,
            };
        if (!mounted || !_catalogItemCurrent(id) || generation != _downloadGeneration) return [];
        _ownedByServer[key] = owned;
        final page = await store.ownedPlaylistWindow(
          item,
          owned,
          client == null ? null : musicAccountScope(client),
          start: manifestStart,
          limit: _MusicCarHostState._pageSize - 2,
          revision: manifestRevision,
        );
        if (!mounted || !_catalogItemCurrent(id) || generation != _downloadGeneration || page == null) return [];
        final children = <Map<String, Object?>>[];
        if (manifestStart == 0) children.addAll(_containerActions(id));
        _playlistRevisions[id] = page.revision;
        for (final track in page.tracks) {
          final row = _item(track, offline: true, parent: (item: item, index: ordinal++));
          _playlistRevisions[row['id'] as String] = page.revision;
          children.add(row);
        }
        if (page.next != null) {
          final cursor = base64Url.encode(utf8.encode(jsonEncode([id, page.next, ordinal, page.revision, generation])));
          children.add(_folder('playlistPage:$cursor', t.fileSources.loadMore));
        }
        return children;
      }
      if (!mounted || !_catalogItemCurrent(id)) return [];
      final scope = await MusicReadScope.forItem(context, item, selectedClient: client, offline: true);
      if (scope == null || !scope.current || !_catalogItemCurrent(id)) return [];
      final tracks = scope.offlineTracks;
      final children = item.kind == MediaKind.artist
          ? _offlineGroups(tracks, albums: true)
          : tracks.indexed.map((pair) => _item(pair.$2, offline: true, parent: (item: item, index: pair.$1)));
      return _containerPage(id, offset, children);
    }
    final client = _authorizations[id]?.client;
    if (client == null ||
        !_catalogItemCurrent(id) ||
        hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}')) {
      return [];
    }
    bool itemCurrent() =>
        _catalogItemCurrent(id) &&
        !hidden.isDisposed &&
        !hidden.hiddenLibraryKeys.contains('${item.serverId}:${item.libraryId}') &&
        (item.kind == MediaKind.playlist ||
            !libraryProvider.isDisposed &&
                libraryProvider.libraries.any(
                  (library) =>
                      library.serverId == item.serverId &&
                      library.id == item.libraryId &&
                      library.backend == item.backend &&
                      !library.hidden,
                ));
    bool visibleChild(MediaItem child) =>
        child.id.isNotEmpty &&
        child.backend == client.backend &&
        child.serverId == item.serverId &&
        (item.kind == MediaKind.playlist ||
            child.libraryId == item.libraryId ||
            item.kind == MediaKind.album &&
                child.libraryId == null &&
                client.backend.usesMediaBrowserApi &&
                child.parentId == item.id) &&
        !hidden.hiddenLibraryKeys.contains('${child.serverId}:${child.libraryId}');
    if (!itemCurrent()) return [];
    if (item.kind == MediaKind.playlist) {
      final page = await client.fetchPlaylistPage(item.id, start: offset, size: (_MusicCarHostState._pageSize - 2));
      if (!itemCurrent()) return [];
      if (page.offset != offset ||
          page.items.length > (_MusicCarHostState._pageSize - 2) ||
          page.totalCount < offset + page.items.length ||
          page.items.isEmpty && page.totalCount > offset) {
        throw const FormatException('Invalid music car playlist page');
      }
      return [
        if (offset == 0) ..._containerActions(id),
        for (final (i, child) in page.items.indexed)
          if (child.kind == MediaKind.track && visibleChild(child))
            _item(child, parent: (item: item, index: offset + i)),
        if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
          _nextPage(id, offset + page.items.length),
      ];
    }
    final LibraryPage<MediaItem> page;
    if (item.kind == MediaKind.artist) {
      if (client is ArtistAlbumPagingClient) {
        final albumPager = client as ArtistAlbumPagingClient;
        page = await albumPager.fetchArtistAlbumsPage(item, start: offset, size: (_MusicCarHostState._pageSize - 2));
      } else {
        final albums = await client.fetchArtistAlbums(item);
        final safeOffset = offset.clamp(0, albums.length).toInt();
        final end = (safeOffset + (_MusicCarHostState._pageSize - 2)).clamp(0, albums.length).toInt();
        page = LibraryPage(items: albums.sublist(safeOffset, end), totalCount: albums.length, offset: offset);
      }
    } else if (item.kind == MediaKind.album) {
      page = await client.fetchMusicTracksPage(
        item.id,
        kind: MediaKind.album,
        libraryId: item.libraryId,
        start: offset,
        size: (_MusicCarHostState._pageSize - 2),
      );
    } else {
      return [];
    }
    if (!itemCurrent()) return [];
    if (page.offset != offset ||
        page.items.length > (_MusicCarHostState._pageSize - 2) ||
        page.totalCount < offset + page.items.length ||
        page.items.isEmpty && page.totalCount > offset) {
      throw const FormatException('Invalid music car catalog page');
    }
    return [
      if (offset == 0) ..._containerActions(id),
      for (final (i, child) in page.items.indexed)
        if (visibleChild(child) &&
            (item.kind == MediaKind.artist
                ? child.kind == MediaKind.album
                : child.kind == MediaKind.track && child.parentId == item.id))
          _item(
            child.libraryId == null ? child.copyWith(libraryId: item.libraryId) : child,
            parent: item.kind == MediaKind.album ? (item: item, index: offset + i) : null,
          ),
      if (page.items.isNotEmpty && offset + page.items.length < page.totalCount)
        _nextPage(id, offset + page.items.length),
    ];
  }

  Future<List<Map<String, Object?>>> _searchAudiobooks(String query) async {
    final sources = _sourceController;
    final normalized = query.trim();
    if (sources == null ||
        sources.blocked ||
        _profileId == null ||
        sources.profileId != _profileId ||
        normalized.isEmpty ||
        normalized.length > 200) {
      return [];
    }
    try {
      final page = await sources.repository.entriesPage(
        _profileId,
        shelf: PublicationShelf.audiobooks,
        query: normalized,
        limit: 100,
      );
      if (!mounted || !_current || sources.profileId != _profileId || sources.blocked) return [];
      final podcasts = await sources.repository.podcastEntries(_profileId, query: normalized, limit: 50);
      if (!_current || sources.profileId != _profileId || sources.blocked) return [];
      final configured = sources.sources.map((source) => source.id).toSet();
      return [
        for (final entry in [...page.items, ...podcasts])
          if (_isSpoken(entry) && entry.audio.isNotEmpty && !entry.unavailable && configured.contains(entry.sourceId))
            _audiobookItem(entry),
      ];
    } on Object {
      // A damaged or unavailable book index must not break music search.
      return [];
    }
  }

  Future<List<MediaItem>> _search(String query) async {
    final term = _voiceName(query);
    if (term.isEmpty || query.length > 200) return [];
    final generation = _profiles.identityMutationGeneration;
    bool current() => mounted && _current && generation == _profiles.identityMutationGeneration;
    final local = await _visibleDownloads();
    if (!mounted || !current()) return [];
    final matches = <String, ({MediaItem item, int rank, bool Function() valid})>{};
    void add(MediaItem item, bool Function() valid, {required bool remote}) {
      final title = _voiceName(item.displayTitle);
      final artist = _voiceName(item.trackArtistTitle ?? '');
      final rank = title == term
          ? (item.kind == MediaKind.track ? 1 : 0)
          : title.startsWith(term)
          ? 2
          : title.contains(term)
          ? 3
          : artist.contains(term)
          ? 4
          : 5;
      if (!remote && rank == 5) return;
      matches.putIfAbsent('${item.backend.name}:${item.globalKey}', () => (item: item, rank: rank, valid: valid));
    }

    for (final track in local) {
      add(track, current, remote: false);
    }
    final denied = _hiddenCarLibraries();
    final clients = context.read<MultiServerProvider>().serverManager.visibleOnlineClients.values.toList();
    var next = 0, finished = false;
    Future<void> worker() async {
      while (!finished && next < clients.length) {
        if (!mounted || !current()) return;
        final client = clients[next++];
        final authorized = _readClient(client);
        final excluded = context
            .read<LibrariesProvider>()
            .libraries
            .where((l) => l.serverId == client.serverId.value && denied.contains(l.globalKey))
            .map((l) => l.id)
            .toSet();
        try {
          final items = await client
              .searchItems(query, limit: 30, excludedLibraryIds: excluded)
              .timeout(const Duration(milliseconds: 850));
          if (finished || !current() || !authorized()) continue;
          for (final item in items) {
            if (item.serverId == client.serverId.value &&
                item.backend == client.backend &&
                const [MediaKind.track, MediaKind.album, MediaKind.artist, MediaKind.playlist].contains(item.kind)) {
              add(item, authorized, remote: true);
            }
          }
        } catch (_) {
          /* best-effort: Keep matches from the other servers and downloads. */
        }
      }
    }

    final budget = Duration(milliseconds: matches.values.any((r) => r.rank <= 1) ? 550 : 2100);
    await Future.wait(List.generate(clients.length.clamp(0, 4), (_) => worker())).timeout(budget, onTimeout: () => []);
    finished = true;
    if (!current()) return [];
    final hidden = _hiddenCarLibraries();
    final visible =
        matches.values.where((r) => r.valid() && !hidden.contains('${r.item.serverId}:${r.item.libraryId}')).toList()
          ..sort((a, b) {
            final rank = a.rank.compareTo(b.rank);
            if (rank != 0) return rank;
            final title = a.item.displayTitle.compareTo(b.item.displayTitle);
            return title != 0 ? title : a.item.globalKey.compareTo(b.item.globalKey);
          });
    return visible.take(100).map((r) => r.item).toList();
  }
}
