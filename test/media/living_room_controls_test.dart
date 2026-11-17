import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focused_media_play.dart';
import 'package:plezy/media/episode_collection.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/receiver_audio.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/projector_viewport.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  test('only an absent numbered episode in the same season creates a gap', () {
    episode(int n, {int season = 1, String show = 'show', int? end}) => testMediaItem(
      id: '$show-$season-$n',
      kind: MediaKind.episode,
      index: n,
      parentIndex: season,
      grandparentId: show,
      serverId: 'a',
      raw: {'IndexNumberEnd': ?end},
    );
    expect(missingEpisodeBefore(episode(3), episode(6), []), 4);
    expect(missingEpisodeBefore(episode(3, end: 5), episode(6), []), isNull);
    expect(missingEpisodeBefore(episode(3), episode(5), [episode(4)]), isNull);
    expect(missingEpisodeBefore(episode(3), episode(5, show: 'other'), []), isNull);
    expect(missingEpisodeBefore(episode(1, season: 0), episode(4, season: 0), []), isNull);
    expect(missingEpisodeBefore(episode(3), episode(1, season: 2), []), isNull);
  });

  test('receiver follows the selected source and preserves stereo and native AC-3', () {
    final source = MediaSourceInfo(
      videoUrl: '',
      chapters: [],
      subtitleTracks: [],
      audioTracks: [
        MediaAudioTrack(id: 3, selected: false, codec: 'ac3', channels: 6),
        MediaAudioTrack(id: 6, selected: true, codec: 'aac', channels: 6),
        MediaAudioTrack(id: 9, selected: false, codec: 'aac', channels: 2),
        MediaAudioTrack(id: 12, selected: false, codec: 'truehd', channels: 8),
      ],
    );
    expect(needsReceiverAc3(source, null), isTrue);
    expect(needsReceiverAc3(source, 3), isFalse);
    expect(needsReceiverAc3(source, 9), isFalse);
    expect(needsReceiverAc3(source, 12), isTrue);
    expect(needsReceiverAc3(source, 25), isFalse);
  });

  testWidgets('Play dispatches once while focus belongs to the poster; OK stays independent', (tester) async {
    var plays = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FocusedMediaPlay(
          play: () {
            plays++;
            return true;
          },
          child: Focus(
            focusNode: node,
            autofocus: true,
            onKeyEvent: (_, event) => FocusedMediaPlay.handle(event),
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(plays, 1);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('details'))));
    await tester.pumpAndSettle();
    expect(FocusedMediaPlay.fromPrimaryFocus(), isFalse);
  });

  testWidgets('the projector viewport applies four saved edges and restores the full surface', (tester) async {
    resetSharedPreferencesForTest();
    final settings = await SettingsService.getInstance();
    final marker = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectorViewport(child: SizedBox.expand(key: marker)),
      ),
    );
    final full = tester.getRect(find.byKey(marker));
    await settings.write(SettingsService.projectorInsets, ['100', '50', '200', '150']);
    await tester.pump();
    final resized = tester.getRect(find.byKey(marker));
    expect(resized, Rect.fromLTRB(full.width * .1, full.height * .05, full.width * .8, full.height * .85));
    expect(MediaQuery.sizeOf(marker.currentContext!), resized.size);
    await settings.write(SettingsService.projectorInsets, <String>[]);
    await tester.pump();
    expect(tester.getRect(find.byKey(marker)), full);
    expect(projectorInsets(['-4', 'x', '600', '40']), [0, 0, 250, 40]);
  });
}
