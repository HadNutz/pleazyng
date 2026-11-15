import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/subtitle_automatic_fetch.dart';
import 'package:plezy/widgets/subtitle_automatic_fetch_status.dart';

void main() {
  group('SubtitleAutomaticFetch', () {
    test('cancellation releases a pending wait and aborts its signal', () async {
      final controller = SubtitleAutomaticFetch();
      addTearDown(controller.dispose);
      final attempt = controller.start(isCurrent: () => true);
      final pending = Completer<String>();
      String? selectedTrack;
      final wait = attempt.wait(() => pending.future).then((trackId) => selectedTrack = trackId);

      controller.cancel();
      pending.complete('late-provider-track');

      await expectLater(wait, throwsA(isA<SubtitleFetchRetiredException>()));
      expect(attempt.abort.isAborted, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.stage, SubtitleFetchStage.cancelled);
      expect(selectedTrack, isNull);
    });

    test('one deadline bounds a provider operation that never completes', () async {
      final controller = SubtitleAutomaticFetch(budget: const Duration(milliseconds: 40));
      addTearDown(controller.dispose);
      final attempt = controller.start(isCurrent: () => true);
      final stopwatch = Stopwatch()..start();

      await expectLater(
        attempt.wait<String>(() => Completer<String>().future),
        throwsA(isA<SubtitleFetchRetiredException>()),
      );

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(controller.stage, SubtitleFetchStage.expired);
      expect(controller.busy, isFalse);
      expect(attempt.abort.isAborted, isTrue);
    });

    testWidgets('status exposes skip, cancellation and explicit retry', (tester) async {
      final controller = SubtitleAutomaticFetch();
      addTearDown(controller.dispose);
      var retries = 0;
      controller.start(isCurrent: () => true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleAutomaticFetchStatus(controller: controller, onSearchAgain: () => retries++),
          ),
        ),
      );
      expect(find.text('Loading...'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(controller.stage, SubtitleFetchStage.cancelled);
      expect(find.text('Stopped. The server may still finish a download it already accepted.'), findsNothing);
      expect(find.text('Search Subtitles'), findsOneWidget);

      await tester.tap(find.text('Search Subtitles'));
      expect(retries, 1);
    });
  });
}
