import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';

typedef IptvSportsFeed = ({LiveTvChannel channel, LiveTvProgram program});

final class IptvSportsFixture {
  IptvSportsFixture(this.firstTeam, this.secondTeam, this.startsAt, this.competition);
  final String firstTeam;
  final String secondTeam;
  final int startsAt;
  final String competition;
  final feeds = <IptvSportsFeed>[];

  static final _separator = RegExp(r'\s+(?:vs\.?|v\.?|at|@|contre|gegen|contra)\s+', caseSensitive: false);
  static final _sports = RegExp(
    r'\b(?:sports?|hockey|football|soccer|basketball|baseball|tennis|rugby|volleyball|cricket|lacrosse|softball|handball|futsal|fútbol|futebol|fussball|fußball|NHL|NFL|NBA|WNBA|MLB|MLS|AHL|ECHL|SPHL|FPHL|UEFA|FIFA|NCAA|CFL|NWSL|EPL|ATP|WTA)\b',
    caseSensitive: false,
  );
  static final _indirect = RegExp(
    r'\b(?:replay|rerun|highlights?|documentary|classics?|preview|recap|pre[ -]?game|post[ -]?game)\b',
    caseSensitive: false,
  );
  static final _league = RegExp(
    r'\b(?:NHL|NFL|NBA|WNBA|MLB|MLS|AHL|ECHL|SPHL|FPHL|UEFA|FIFA|NCAA|CFL|NWSL|EPL|ATP|WTA)\b',
    caseSensitive: false,
  );
  static final _feedSuffix = RegExp(
    r'\s*[\[(](?:home|away|national|alternate|english|french|spanish)(?: feed| broadcast)?[\])]\s*$',
    caseSensitive: false,
  );
  static final _spaces = RegExp(r'\s+');
  static String teamKey(String label) => label.toLowerCase().trim().replaceAll(_spaces, ' ');

  static List<IptvSportsFixture> fromGuide(List<LiveTvChannel> channels, Iterable<LiveTvProgram> programmes) {
    final playable = {
      for (final c in channels)
        if (c.iptvSourceId != null && !c.iptvParentalLocked) c.key: c,
    };
    final byMatch = <(int, String, String, String), IptvSportsFixture>{};
    final seen = <(String, int, String)>{};
    for (final p in programmes) {
      final c = playable[p.channelIdentifier], start = p.beginsAt, end = p.endsAt;
      if (c == null || start == null || end == null || end <= start) continue;
      final title = p.title.trim(), tags = '${p.type ?? ''} $title';
      if (!_sports.hasMatch(tags) || _indirect.hasMatch(tags)) continue;
      var matchup = title.replaceFirst(_feedSuffix, '');
      final colon = matchup.indexOf(':');
      if (colon >= 0 && _sports.hasMatch(matchup.substring(0, colon))) matchup = matchup.substring(colon + 1).trim();
      final teams = matchup.split(_separator).map((value) => value.trim()).toList();
      if (teams.length != 2 || teams.any((t) => t.isEmpty || t.length > 100)) continue;
      final keys = teams.map(teamKey).toList()..sort();
      if (keys.first == keys.last) continue;
      final league = (_league.firstMatch(tags)?.group(0) ?? '').toUpperCase();
      final key = (start, league, keys.first, keys.last);
      final fixture = byMatch.putIfAbsent(key, () => IptvSportsFixture(teams.first, teams.last, start, league));
      if (seen.add((c.key, start, p.title))) fixture.feeds.add((channel: c, program: p));
    }
    return byMatch.values.toList()..sort((left, right) {
      final time = left.startsAt.compareTo(right.startsAt);
      return time != 0 ? time : left.firstTeam.compareTo(right.firstTeam);
    });
  }
}
