import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/sheets/chapter_sheet.dart';

import 'package:plezy/services/media_bookmark_service.dart';
import 'package:plezy/services/settings_service.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('unassigned bookmarks can be recovered on known and indistinguishable cuts', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    for (final version in ['extended', null]) {
      final mark = await MediaBookmarkService.add('item', 'Original mark', 1000);
      final player = _FakePlayer();
      await _pumpSheet(tester, player: player, canControl: true, legacyKey: 'item', versionKey: version);
      expect(find.text(t.bookmarkMigration.unassigned), findsOneWidget);
      await tester.tap(find.text('Original mark'));
      await tester.pumpAndSettle();
      expect(player.seeks, isEmpty);
      if (version != null) {
        expect(MediaBookmarkService.forMedia(version).single.id, mark.id);
      } else {
        expect(MediaBookmarkService.forMedia('item').single.id, mark.id);
        await tester.tap(find.byTooltip(t.videoControls.deleteBookmark));
        await tester.pumpAndSettle();
      }
      expect(MediaBookmarkService.forMedia('item'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('denied chapter tile stays open and cannot seek by pointer or select', (tester) async {
    final player = _FakePlayer();
    await _pumpSheet(tester, player: player, canControl: false);

    await tester.tap(find.text('Chapter One'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(player.seeks, isEmpty);
    expect(find.text('Chapter One'), findsOneWidget);
  });

  testWidgets('authorized chapter seeks, reports completion, and closes', (tester) async {
    final player = _FakePlayer();
    final completions = <Duration>[];
    await _pumpSheet(tester, player: player, canControl: true, onCompleted: completions.add);

    await tester.tap(find.text('Chapter One'));
    await tester.pumpAndSettle();

    expect(player.seeks, [const Duration(seconds: 10)]);
    expect(completions, [const Duration(seconds: 10)]);
    expect(find.text('Chapter One'), findsNothing);
  });
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  required _FakePlayer player,
  required bool canControl,
  ValueChanged<Duration>? onCompleted,
  String? legacyKey,
  String? versionKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [testMonoTokens]),
      home: OverlaySheetHost(
        child: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => OverlaySheetController.of(context).show<void>(
                builder: (_) => ChapterSheet(
                  player: player,
                  chapters: [MediaChapter(id: 1, startTimeOffset: 10000, title: 'Chapter One')],
                  chaptersLoaded: true,
                  canControl: canControl,
                  legacyBookmarkKey: legacyKey,
                  bookmarkMediaKey: versionKey,
                  onSeekCompleted: onCompleted,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

class _FakePlayer implements Player {
  final List<Duration> seeks = [];

  @override
  String get playerType => 'exoplayer';

  @override
  PlayerState get state => PlayerState(duration: const Duration(minutes: 30), seekable: true);

  @override
  PlayerStreams get streams => const PlayerStreams(
    playing: Stream<bool>.empty(),
    completed: Stream<bool>.empty(),
    buffering: Stream<bool>.empty(),
    position: Stream<Duration>.empty(),
    duration: Stream<Duration>.empty(),
    seekable: Stream<bool>.empty(),
    buffer: Stream<Duration>.empty(),
    volume: Stream<double>.empty(),
    rate: Stream<double>.empty(),
    tracks: Stream<Tracks>.empty(),
    track: Stream<TrackSelection>.empty(),
    log: Stream<PlayerLog>.empty(),
    error: Stream<PlayerError>.empty(),
    audioDevice: Stream<AudioDevice>.empty(),
    audioDevices: Stream<List<AudioDevice>>.empty(),
    bufferRanges: Stream<List<BufferRange>>.empty(),
    playbackRestart: Stream<void>.empty(),
    backendSwitched: Stream<void>.empty(),
  );
  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
