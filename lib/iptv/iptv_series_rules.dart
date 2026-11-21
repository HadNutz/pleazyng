import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/livetv_channel.dart';

typedef IptvSeriesRule = ({
  String id,
  String profileId,
  String sourceId,
  String channelId,
  String title,
  String channelName,
  int anchor,
});
String _titleKey(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
final _episodeNumber = RegExp(r'\b(?:s|season\s*)(\d{1,3})\s*(?:e|episode\s*)(\d{1,4})\b', caseSensitive: false);
const _uuid = Uuid();

class IptvSeriesRules {
  IptvSeriesRules(this.db, this.channelsForSource);
  final Future<List<LiveTvChannel>> Function(String profile, String source) channelsForSource;
  final AppDatabase db;

  Future<List<IptvSeriesRule>> list(String profileId, {String? sourceId}) async {
    final rows = await db
        .customSelect(
          'SELECT r.*,s.profile_id,c.title AS channel_name FROM iptv_series_rules r JOIN iptv_sources s ON s.id=r.source_id LEFT JOIN iptv_channels c ON c.source_id=r.source_id AND c.channel_id=r.channel_id WHERE s.profile_id=? AND (? IS NULL OR s.id=?) ORDER BY r.title COLLATE NOCASE,r.id',
          variables: [Variable(profileId), Variable(sourceId), Variable(sourceId)],
        )
        .get();
    return [
      for (final r in rows)
        (
          id: r.read<String>('id'),
          profileId: profileId,
          sourceId: r.read<String>('source_id'),
          channelId: r.read<String>('channel_id'),
          title: r.read<String>('title'),
          channelName: r.readNullable<String>('channel_name') ?? r.read<String>('channel_id'),
          anchor: r.read<int>('anchor'),
        ),
    ];
  }

  Future<void> add(String profile, String source, String channel, String title, int start) async {
    final name = title.trim();
    if (name.isEmpty || name.length > 512) throw const FormatException('Invalid programme title');
    await db.runIdentityMutation(
      () => db.transaction(() async {
        final visible = await channelsForSource(profile, source);
        if (!visible.any((c) => c.iptvChannelId == channel && !c.iptvParentalLocked)) {
          throw StateError('Channel unavailable');
        }
        await db.customStatement(
          'INSERT INTO iptv_series_rules(id,source_id,channel_id,title,title_key,anchor) VALUES(?,?,?,?,?,?) ON CONFLICT(source_id,channel_id,title_key) DO UPDATE SET title=excluded.title,anchor=excluded.anchor',
          [_uuid.v4(), source, channel, name, _titleKey(name), (start ~/ 60) % 1440],
        );
        await reconcile(profile, source);
      }),
    );
  }

  Future<void> remove(String profile, String id) => db.runIdentityMutation(
    () => db.transaction(() async {
      await db.customStatement(
        "DELETE FROM iptv_recording_schedules WHERE profile_id=? AND state='scheduled' AND id IN (SELECT schedule_id FROM iptv_series_airings WHERE rule_id=?)",
        [profile, id],
      );
      await db.customStatement(
        'DELETE FROM iptv_series_rules WHERE id=? AND source_id IN (SELECT id FROM iptv_sources WHERE profile_id=?)',
        [id, profile],
      );
    }),
  );

  Future<bool> canCapture(String id, String profile, String source, String channel) async {
    final row = await db
        .customSelect('SELECT 1 FROM iptv_series_airings WHERE schedule_id=?', variables: [Variable(id)])
        .getSingleOrNull();
    if (row == null) return true;
    return (await channelsForSource(profile, source)).any((c) => c.iptvChannelId == channel && !c.iptvParentalLocked);
  }

  /// Called within the same transaction that publishes the guide or creates a rule.
  Future<void> reconcile(String profile, String source) async {
    final rules = await list(profile, sourceId: source);
    if (rules.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final allowed = {
      for (final c in await channelsForSource(profile, source))
        if (!c.iptvParentalLocked) c.iptvChannelId,
    };
    for (final rule in rules) {
      if (!allowed.contains(rule.channelId)) continue;
      final rows = await db
          .customSelect(
            'SELECT p.* FROM iptv_programmes p JOIN iptv_channels c ON c.source_id=p.source_id AND c.channel_id=p.channel_id WHERE p.source_id=? AND p.channel_id=? AND p.ends_at>? ORDER BY p.begins_at,p.title',
            variables: [Variable(source), Variable(rule.channelId), Variable(now)],
          )
          .get();
      final previous = await db
          .customSelect(
            "SELECT a.episode_key FROM iptv_series_airings a JOIN iptv_recording_schedules s ON s.id=a.schedule_id WHERE a.rule_id=? AND a.episode_key IS NOT NULL AND s.state NOT IN ('failed','missed','cancelled')",
            variables: [Variable(rule.id)],
          )
          .get();
      final episodes = {for (final row in previous) row.read<String>('episode_key')};
      for (final row in rows) {
        final title = row.read<String>('title');
        if (_titleKey(title) != _titleKey(rule.title)) continue;
        final start = row.read<int>('begins_at'), end = row.read<int>('ends_at');
        if (end <= start || end - (start > now ? start : now) > 12 * 3600) continue;
        final match = _episodeNumber.firstMatch('$title ${row.readNullable<String>('summary') ?? ''}');
        final guideId = row.readNullable<String>('episode_id')?.trim();
        final episode = guideId != null && guideId.isNotEmpty
            ? 'xml:$guideId'
            : match == null
            ? null
            : 's${int.parse(match[1]!)}e${int.parse(match[2]!)}';
        if (episode != null && episodes.contains(episode)) continue;
        final delta = ((start ~/ 60) % 1440 - rule.anchor).abs();
        if (episode == null && delta > 90 && 1440 - delta > 90) continue;
        final id = _uuid.v4();
        final made = await db.customUpdate(
          "INSERT OR IGNORE INTO iptv_recording_schedules(id,profile_id,source_id,channel_id,title,programme_title,starts_at,ends_at,state,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,'scheduled',?,?)",
          variables: [
            Variable(id),
            Variable(profile),
            Variable(source),
            Variable(rule.channelId),
            Variable(rule.channelName),
            Variable(title),
            Variable(start),
            Variable(end),
            Variable(now),
            Variable(now),
          ],
        );
        // The unique airing constraint also protects existing one-off and cancelled timers.
        if (made == 0) continue;
        await db.customStatement('INSERT INTO iptv_series_airings(rule_id,schedule_id,episode_key) VALUES (?,?,?)', [
          rule.id,
          id,
          episode,
        ]);
        if (episode != null) episodes.add(episode);
      }
    }
  }
}
