part of '../iptv_source_repository.dart';

extension _IptvVodCatalogPersistence on IptvSourceRepository {
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
