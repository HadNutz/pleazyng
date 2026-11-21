part of '../iptv_source_repository.dart';

extension _IptvLineupPersistence on IptvSourceRepository {
  Future<Map<String, String>> _feedIdentities(String sourceId, List<IptvPlaylistEntry> feeds) async {
    final stored = await _database
        .customSelect(
          'SELECT feed_key,channel_id FROM iptv_feed_identities WHERE source_id=?',
          variables: [Variable(sourceId)],
        )
        .get();
    final known = {for (final row in stored) row.read<String>('feed_key'): row.read<String>('channel_id')};
    final result = <String, String>{};
    final used = <String>{};
    // A canonical ID takes precedence over a historical alias if both return.
    for (final feed in feeds) {
      if (known[feed.id] == feed.id) {
        result[feed.id] = feed.id;
        used.add(feed.id);
      }
    }
    final aliases = <String, List<String>>{};
    for (final feed in feeds) {
      final id = known[feed.id];
      if (id != null && !used.contains(id)) (aliases[id] ??= []).add(feed.id);
    }
    for (final alias in aliases.entries) {
      // If two historical variants reappear together, use the last actual
      // lineup below to decide which still owns the old ordinal.
      if (alias.value.length != 1) continue;
      used.add(alias.key);
      result[alias.value.single] = alias.key;
    }
    if (result.length == feeds.length) return result;
    final rows = await _database
        .customSelect(
          'SELECT channel_id,tvg_id,title,number,group_title,stream_url_ciphertext FROM iptv_channels WHERE source_id=?',
          variables: [Variable(sourceId)],
        )
        .get();
    if (rows.isEmpty) {
      for (final feed in feeds) {
        result.putIfAbsent(feed.id, () => feed.id);
      }
      return result;
    }
    String metadata(String? tvg, String title, String? number, String? group) =>
        jsonEncode([tvg, title.trim().toLowerCase(), number, group]);
    final byMetadata = <String, List<QueryRow>>{};
    for (final row in rows) {
      if (used.contains(row.read<String>('channel_id'))) continue;
      final key = metadata(
        row.readNullable<String>('tvg_id'),
        row.read<String>('title'),
        row.readNullable<String>('number'),
        row.readNullable<String>('group_title'),
      );
      (byMetadata[key] ??= []).add(row);
    }
    final candidates = <String, List<IptvPlaylistEntry>>{};
    for (final feed in feeds.where((f) => !result.containsKey(f.id))) {
      (candidates[metadata(feed.tvgId, feed.title, feed.number, feed.groupTitle)] ??= []).add(feed);
    }
    for (final group in candidates.entries) {
      final old = byMetadata[group.key] ?? const <QueryRow>[];
      final incoming = group.value;
      if (old.length == 1 && incoming.length == 1) {
        result[incoming.single.id] = old.single.read<String>('channel_id');
        continue;
      }
      if (old.isEmpty) continue;
      final exact = {for (final feed in incoming) feed.id};
      for (final row in old) {
        final value = await CredentialVault.reveal(row.read<String>('stream_url_ciphertext'));
        if (value == null) throw const IptvImportException('credential_unavailable');
        final uri = Uri.tryParse(value);
        if (uri == null) continue;
        final first = incoming.first;
        final key = IptvPlaylistParser.feedId(uri, first.title, first.tvgId, first.number, first.groupTitle);
        if (exact.remove(key)) result[key] = row.read<String>('channel_id');
      }
    }
    // A provider can rename or renumber a channel while retaining its
    // address. Require a unique address on each side before reusing its ID.
    final byAddress = <String, List<IptvPlaylistEntry>>{};
    final unmatchedGroups = <String?>{};
    for (final feed in feeds.where((f) => !result.containsKey(f.id))) {
      unmatchedGroups.add(feed.tvgId);
      final key = IptvPlaylistParser.feedId(Uri.parse(feed.streamUrl), '', feed.tvgId, null, null);
      (byAddress[key] ??= []).add(feed);
    }
    if (byAddress.isNotEmpty) {
      final occupied = result.values.toSet();
      final prior = <String, List<String>>{};
      for (final row in rows) {
        final id = row.read<String>('channel_id');
        final group = row.readNullable<String>('tvg_id');
        if (occupied.contains(id) || !unmatchedGroups.contains(group)) continue;
        final value = await CredentialVault.reveal(row.read<String>('stream_url_ciphertext'));
        if (value == null) throw const IptvImportException('credential_unavailable');
        final uri = Uri.tryParse(value);
        if (uri == null) continue;
        final key = IptvPlaylistParser.feedId(uri, '', group, null, null);
        if (byAddress.containsKey(key)) (prior[key] ??= []).add(id);
      }
      for (final priorRow in prior.entries) {
        final incoming = byAddress[priorRow.key]!;
        if (priorRow.value.length == 1 && incoming.length == 1) result[incoming.single.id] = priorRow.value.single;
      }
    }
    for (final feed in feeds) {
      result.putIfAbsent(feed.id, () => feed.id);
    }
    return result;
  }

  Future<_StoredIptvSource> _publishLineup(
    _StoredIptvSource expected,
    List<IptvPlaylistEntry> entries,
    Map<String, String> identities,
  ) async {
    final protectedStreams = await _mapInBatches(entries, (entry) => CredentialVault.protect(entry.streamUrl));
    final protectedCatchup = await _mapInBatches(
      entries,
      (entry) =>
          entry.catchupSource == null ? Future<String?>.value(null) : CredentialVault.protect(entry.catchupSource!),
    );
    final protectedHeaders = await _mapInBatches(
      entries,
      (entry) => entry.streamHeaders.isEmpty
          ? Future<String?>.value(null)
          : CredentialVault.protect(jsonEncode(entry.streamHeaders)),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    return _database.runIdentityMutation(
      () => _database.transaction(() async {
        final current = await _source(expected.profileId, expected.id);
        if (current == null || current.revision != expected.revision || current.generation != expected.generation) {
          throw const IptvImportException('source_changed');
        }
        await _insertRows(
          table: 'iptv_feed_identities',
          replace: true,
          columns: const ['source_id', 'feed_key', 'channel_id'],
          rows: [
            for (final row in identities.entries) [expected.id, row.key, row.value],
          ],
        );
        await _database.customStatement('DELETE FROM iptv_channels WHERE source_id=?', [expected.id]);
        final channelRows = <List<Object?>>[];
        for (var index = 0; index < entries.length; index++) {
          final entry = entries[index];
          channelRows.add([
            expected.id,
            entry.id,
            entry.title,
            entry.tvgId,
            entry.number,
            entry.groupTitle,
            entry.logoUrl,
            protectedCatchup[index],
            entry.catchupDays,
            protectedStreams[index],
            entry.radio ? 1 : 0,
            protectedHeaders[index],
            now,
          ]);
        }
        await _insertRows(
          table: 'iptv_channels',
          columns: const [
            'source_id',
            'channel_id',
            'title',
            'tvg_id',
            'number',
            'group_title',
            'logo_url',
            'catchup_source_ciphertext',
            'catchup_days',
            'stream_url_ciphertext',
            'is_radio',
            'stream_headers_ciphertext',
            'updated_at',
          ],
          rows: channelRows,
        );
        await _database.customStatement(
          '''
        DELETE FROM iptv_channel_overrides
        WHERE source_id=? AND profile_id=?
          AND channel_id NOT IN (SELECT channel_id FROM iptv_channels WHERE source_id=?)
          AND channel_id NOT IN (SELECT channel_id FROM iptv_feed_identities WHERE source_id=?)
      ''',
          [expected.id, expected.profileId, expected.id, expected.id],
        );
        await _database.customStatement(
          '''DELETE FROM iptv_programmes WHERE source_id=?
           AND channel_id NOT IN (SELECT channel_id FROM iptv_channels WHERE source_id=?)''',
          [expected.id, expected.id],
        );
        await _database.customStatement(
          'UPDATE iptv_sources SET generation=generation+1,last_success_at=?,last_error_code=NULL WHERE id=?',
          [now, expected.id],
        );
        return (await _source(expected.profileId, expected.id))!;
      }),
    );
  }

  Future<void> _replaceVodCategories(
    _StoredIptvSource expected,
    IptvVodKind kind,
    List<IptvVodCategory> categories,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.runIdentityMutation(
      () => _database.transaction(() async {
        final current = await _source(expected.profileId, expected.id);
        if (current == null || current.revision != expected.revision) {
          throw const IptvImportException('source_changed');
        }
        await _database.customStatement('DELETE FROM iptv_vod_categories WHERE source_id=? AND kind=?', [
          expected.id,
          kind.name,
        ]);
        if (categories.isNotEmpty) {
          await _insertRows(
            table: 'iptv_vod_categories',
            columns: const ['source_id', 'kind', 'category_id', 'name', 'updated_at'],
            rows: [
              for (final item in categories) [expected.id, kind.name, item.id, item.name, now],
            ],
          );
        }
      }),
    );
  }

  Future<void> _replaceVodItems(
    _StoredIptvSource expected,
    IptvVodKind kind,
    String? categoryId,
    List<IptvVodItem> items,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.runIdentityMutation(
      () => _database.transaction(() async {
        final current = await _source(expected.profileId, expected.id);
        if (current == null || current.revision != expected.revision) {
          throw const IptvImportException('source_changed');
        }
        if (categoryId == null) {
          await _database.customStatement('DELETE FROM iptv_vod_items WHERE source_id=? AND kind=?', [
            expected.id,
            kind.name,
          ]);
        } else {
          await _database.customStatement('DELETE FROM iptv_vod_items WHERE source_id=? AND kind=? AND category_id=?', [
            expected.id,
            kind.name,
            categoryId,
          ]);
        }
        if (items.isNotEmpty) {
          await _insertRows(
            table: 'iptv_vod_items',
            columns: const [
              'source_id',
              'kind',
              'item_id',
              'category_id',
              'title',
              'plot',
              'year',
              'duration_seconds',
              'rating',
              'poster_url',
              'backdrop_url',
              'container_extension',
              'updated_at',
            ],
            rows: [
              for (final item in items)
                [
                  expected.id,
                  kind.name,
                  item.id,
                  item.categoryId,
                  item.title,
                  item.plot,
                  item.year,
                  item.durationSeconds,
                  item.rating,
                  item.posterUrl,
                  item.backdropUrl,
                  item.containerExtension,
                  now,
                ],
            ],
          );
        }
      }),
    );
  }

  void _appendEpisode(List<IptvVodEpisode> target, Object? raw, IptvSourceConfiguration config, int? seasonHint) {
    final row = sourceMap(raw);
    final id = _valueString(row, const ['id', 'stream_id', 'episode_id']);
    final title = _valueString(row, const ['title', 'name', 'episode_name']);
    if (id == null || title == null) {
      return;
    }
    final info = sourceMap(row['info']);
    final season = _valueInt(row, const ['season', 'season_number']) ?? seasonHint ?? 0;
    final episode = _valueInt(row, const ['episode_num', 'episode', 'episode_number', 'index']) ?? 0;
    target.add(
      IptvVodEpisode(
        id: id,
        title: _safeCatalogText(title, 240) ?? 'Episode',
        season: season.clamp(0, 999).toInt(),
        episode: episode.clamp(0, 9999).toInt(),
        plot: _safeCatalogText(
          _valueString(row, const ['plot', 'description']) ?? _valueString(info, const ['plot']),
          4000,
        ),
        durationSeconds:
            _valueInt(row, const ['duration_secs', 'duration']) ??
            _durationSeconds(_valueString(info, const ['duration'])),
        posterUrl: _safeVodArtwork(
          _valueString(info, const ['movie_image', 'cover', 'cover_big']) ?? _valueString(row, const ['cover']),
          config,
        ),
        containerExtension: _iptvSafeExtension(
          _valueString(row, const ['container_extension']) ??
              _valueString(info, const ['container_extension']) ??
              'mp4',
        ),
      ),
    );
  }
}
