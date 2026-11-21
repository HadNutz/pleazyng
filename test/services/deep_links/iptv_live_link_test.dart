import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/iptv/iptv_source_repository.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/services/deep_links/deep_link.dart';
import 'package:plezy/services/deep_links/deep_link_launcher.dart';
import 'package:plezy/utils/snackbar_helper.dart';

class _Servers extends ChangeNotifier implements MultiServerProvider {
  @override
  List<LiveTvServerInfo> get liveTvServers => const [];
  @override
  bool get hasConnectedServers => true;
  @override
  Future<void> checkLiveTvAvailability() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profile extends ChangeNotifier implements ActiveProfileProvider {
  @override
  String get activeId => 'local';
  @override
  int get identityMutationGeneration => 0;
  @override
  Profile? get active => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a source-specific standalone IPTV link reaches the ordinary parental check', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final guide = IptvSourceRepository(db);
    final link = DeepLink.tryParse('pleazyng://live?channel=42&server=src') as LiveLink;
    await tester.runAsync(() async {
      await db.customStatement(
        "INSERT INTO iptv_sources(id,profile_id,display_name,kind,config_ciphertext,created_at) VALUES ('src','local','Local','m3u','x',1)",
      );
      await db.customStatement(
        "INSERT INTO iptv_channels(source_id,channel_id,title,number,stream_url_ciphertext,updated_at) VALUES ('src','news','Local News','42','x',1)",
      );
      await db.customStatement(
        "INSERT INTO iptv_channel_overrides(profile_id,source_id,channel_id,parental_locked) VALUES ('local','src','news',1)",
      );
      final channels = await guide.channels('local');
      expect(link.selectChannel(channels)?.displayName, 'Local News');
    });
    late BuildContext launchContext;
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            Provider<IptvSourceRepository>.value(value: guide),
            ChangeNotifierProvider<ActiveProfileProvider>(create: (_) => _Profile()),
            ChangeNotifierProvider<MultiServerProvider>(create: (_) => _Servers()),
          ],
          child: MaterialApp(
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  launchContext = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await launchDeepLink(launchContext, link, isOffline: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(t.iptv.parentalAccessDenied), findsOneWidget);
    expect(find.text(t.deepLinks.noLiveTv), findsNothing);
    await tester.runAsync(() => db.close());
  });
}
