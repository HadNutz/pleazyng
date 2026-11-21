import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/iptv/iptv_sports_guide.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';

void main() {
  test('simulcasts share a fixture while doubleheaders, inaccessible feeds and unrelated shows stay distinct', () {
    final channels = [
      for (final key in ['home', 'away', 'locked'])
        LiveTvChannel(key: key, iptvSourceId: 'source', iptvChannelId: key, iptvParentalLocked: key == 'locked'),
    ];
    LiveTvProgram airing(String title, String key, int start, {String category = 'Sports'}) =>
        LiveTvProgram(title: title, type: category, channelIdentifier: key, beginsAt: start, endsAt: start + 3000);
    final fixtures = IptvSportsFixture.fromGuide(channels, [
      airing('NHL: North Bears vs South Eagles (Home)', 'home', 1000),
      airing('NHL: South Eagles @ North Bears [Away]', 'away', 1000),
      airing('NHL: North Bears vs South Eagles', 'locked', 1000),
      airing('NHL: North Bears vs South Eagles', 'removed', 1000),
      airing('NHL: North Bears vs South Eagles', 'home', 9000),
      airing('North vs South', 'home', 1300, category: 'Documentary'),
      airing('NHL: North Bears vs South Eagles (Replay)', 'home', 1400),
      airing('NHL: North Bears vs South Eagles highlights', 'home', 1500),
      airing('NHL: North Bears vs South Eagles at Unknown', 'home', 1600),
    ]);
    expect(fixtures.map((f) => f.startsAt), [1000, 9000]);
    expect(fixtures.first.competition, 'NHL');
    expect(fixtures.first.feeds.map((feed) => feed.channel.key), ['home', 'away']);
  });
}
