import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/models/home_section_config.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/home_layout_settings_screen.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/music_experience_fakes.dart';
import '../../test_helpers/prefs.dart';

class _Collections extends DataAggregationService {
  _Collections(super.manager);

  @override
  Future<CollectionAggregationResult> getCollectionsFromAllServers({
    Set<String>? hiddenLibraryKeys,
    Set<String>? serverIds,
    Set<String>? collectionKeys,
  }) async => (
    // A previous response can include a now-hidden library.
    collections: [
      for (final library in ['a', 'b'])
        testMediaItem(id: 'box', title: 'Shared box', kind: MediaKind.collection, libraryId: library, serverId: 's'),
    ],
    libraryKinds: const {'s:a': MediaKind.movie, 's:b': MediaKind.movie},
    succeededServerIds: {'s'},
    cancelledServerIds: <String>{},
    failedServerIds: <String>{},
  );
}

void main() {
  testWidgets('the open Home row editor deduplicates collections and removes hidden choices', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.homeSections, [
      HomeSectionConfig(id: 'row', title: 'My movie row', kind: HomeSectionKind.movieCollections),
    ]);
    final libraries = LibrariesProvider();
    await libraries.updateLibraryOrder([
      for (final id in ['a', 'b'])
        MediaLibrary(id: id, title: 'Movies $id', backend: MediaBackend.jellyfin, kind: MediaKind.movie, serverId: 's'),
    ]);
    final hidden = HiddenLibrariesProvider();
    await hidden.ensureInitialized();
    final manager = MultiServerManager()..debugRegisterClientForTesting(ExperienceClient());
    final servers = MultiServerProvider(manager, _Collections(manager));
    addTearDown(() {
      servers.dispose();
      hidden.dispose();
      libraries.dispose();
      manager.dispose();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
        ],
        child: TranslationProvider(child: const MaterialApp(home: HomeLayoutSettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    final edit = find.widgetWithText(ListTile, 'My movie row');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final box = find.text('Shared box');
    expect(box, findsOneWidget);
    await hidden.hideLibrary('s:a');
    await tester.pumpAndSettle();
    expect(find.text('Movies a'), findsNothing);
    expect(box, findsOneWidget);
    servers.setVisibleServerIds({});
    await tester.pumpAndSettle();
    expect(find.text('Movies b'), findsNothing);
    expect(box, findsNothing);
    servers.setVisibleServerIds({'s'});
    await tester.pumpAndSettle();
    expect(box, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
