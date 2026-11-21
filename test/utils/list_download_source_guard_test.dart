import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/utils/content_utils.dart';
import 'package:plezy/utils/download_utils.dart';
import 'package:plezy/utils/quality_preset_labels.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/music_experience_fakes.dart';

class _Downloads implements DownloadProvider {
  int calls = 0;
  TranscodeQualityPreset? queuedQuality;
  @override
  Future<int> queueListDownload(
    List<MediaItem> items,
    MediaServerClient client, {
    DownloadFilter filter = DownloadFilter.all,
    MediaItem? playlist,
    SyncRuleItem? syncRule,
    TranscodeQualityPreset? downloadQuality,
    bool Function()? sourceCurrent,
  }) async {
    if (sourceCurrent?.call() != true) throw StateError('Retired test queue');
    calls++;
    queuedQuality = downloadQuality;
    return items.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected download mutation');
}

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));
  Future<BuildContext> pump(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('retired list fetch cannot open download options', (tester) async {
    final context = await pump(tester), downloads = _Downloads();
    var current = true;
    final pending = Completer<List<MediaItem>>();
    final result = fetchAndQueueListDownload(
      context,
      client: ExperienceClient(),
      downloadProvider: downloads,
      fetchItems: () => pending.future,
      rootMetadata: testMediaItem(kind: MediaKind.playlist),
      targetType: ContentTypes.playlist,
      sourceCurrent: () => current,
    );
    current = false;
    pending.complete([testMediaItem(kind: MediaKind.track)]);
    await result;
    await tester.pumpAndSettle();
    expect(downloads.calls, 0);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed video list prompts once and forwards the selected quality for the whole batch', (tester) async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.askDownloadQualityEachTime, true);
    final context = await pump(tester), downloads = _Downloads();
    final result = showListDownloadOptionsAndQueue(
      context,
      client: ExperienceClient(),
      downloadProvider: downloads,
      rootMetadata: testMediaItem(kind: MediaKind.collection),
      targetType: ContentTypes.collection,
      items: [
        testMediaItem(kind: MediaKind.show),
        testMediaItem(kind: MediaKind.movie),
        testMediaItem(kind: MediaKind.track),
      ],
      sourceCurrent: () => true,
      allowSync: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.downloads.allEpisodes));
    await tester.pumpAndSettle();
    expect(downloads.calls, 0);
    const chosen = TranscodeQualityPreset.p1080_20mbps;
    await tester.tap(find.text(qualityPresetLabel(chosen)));
    await tester.pumpAndSettle();
    expect((await result)?.count, 3);
    expect(downloads.queuedQuality, chosen);
  });

  for (final retired in [false, true]) {
    testWidgets(
      retired
          ? 'retired list choice cannot queue or persist a sync rule'
          : 'shared list choice downloads once without offering a sync rule',
      (tester) async {
        final context = await pump(tester), downloads = _Downloads();
        var current = true;
        final result = showListDownloadOptionsAndQueue(
          context,
          client: ExperienceClient(),
          downloadProvider: downloads,
          rootMetadata: testMediaItem(kind: MediaKind.playlist),
          targetType: ContentTypes.playlist,
          items: [testMediaItem(kind: MediaKind.track)],
          sourceCurrent: () => current,
          allowSync: false,
        );
        await tester.pumpAndSettle();
        if (retired) current = false;
        await tester.tap(find.text(t.downloads.allEpisodes));
        await tester.pumpAndSettle();
        final queued = await result;
        expect(downloads.calls, retired ? 0 : 1);
        expect(queued?.count, retired ? isNull : 1);
        expect(find.text(t.downloads.keepSynced), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
