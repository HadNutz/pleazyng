import 'dart:ui' show DisplayFeature, DisplayFeatureType, DisplayFeatureState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/fold_browser.dart';
import 'package:plezy/widgets/fold_regions.dart';

const full = Rect.fromLTWH(0, 0, 960, 700);
DisplayFeature feature(
  Rect bounds, {
  DisplayFeatureType type = DisplayFeatureType.hinge,
  DisplayFeatureState state = DisplayFeatureState.unknown,
}) => DisplayFeature(bounds: bounds, type: type, state: state);

void main() {
  test('continuous flat folds stay immersive, half-open folds and physical hinges divide', () {
    const line = Rect.fromLTWH(0, 350, 960, 0);
    for (final state in DisplayFeatureState.values) {
      final layout = FoldRegions(full, [feature(line, type: DisplayFeatureType.fold, state: state)], TextDirection.ltr);
      expect(layout.panes.length, state == DisplayFeatureState.postureHalfOpened ? 2 : 1);
    }
    final gap = feature(const Rect.fromLTWH(460, 0, 40, 700), state: DisplayFeatureState.postureFlat);
    final pane = FoldRegions(const Rect.fromLTWH(480, 100, 200, 300), [gap], TextDirection.ltr);
    expect(pane.panes, [const Rect.fromLTWH(20, 0, 180, 300)]);
  });

  test('both hinges avoid dead pixels with a stable RTL reading order', () {
    final gaps = [feature(const Rect.fromLTWH(660, 0, 18, 700)), feature(const Rect.fromLTWH(320, 0, 20, 700))];
    final layout = FoldRegions(full, gaps, TextDirection.rtl);
    expect(layout.panes.map((p) => p.left), [678, 340, 0]);
    expect(layout.panes.map((p) => p.width), [282, 320, 320]);
    expect(layout.usable(width: 300).length, 2);
  });

  testWidgets('camera adds pane-local safe padding and leaves the picture viewport available', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = full.size;
    addTearDown(tester.view.reset);
    final layout = FoldRegions(full, [
      feature(const Rect.fromLTWH(100, 2, 40, 20), type: DisplayFeatureType.cutout),
    ], TextDirection.ltr);
    late EdgeInsets padding;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Stack(
            children: [
              layout.place(
                context,
                layout.full,
                Builder(
                  builder: (context) {
                    padding = MediaQuery.paddingOf(context);
                    return const SizedBox.expand();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(padding.top, 22);
    expect(layout.largest, full);
  });

  testWidgets('folding and reopening preserve the detail route, text selection and browse state', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = full.size;
    addTearDown(tester.view.reset);
    final hinge = feature(const Rect.fromLTWH(470, 0, 20, 700));
    tester.view.displayFeatures = [hinge];
    final key = GlobalKey<FoldBrowserState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FoldBrowser(
            key: key,
            child: Builder(
              builder: (context) => TextButton(
                child: const Text('Open'),
                onPressed: () => FoldBrowserScope.of(
                  context,
                )!.detail!()!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: TextField()))),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'chapter 17');
    final editor = tester.state<EditableTextState>(find.byType(EditableText));
    for (final features in [
      <DisplayFeature>[],
      [hinge],
      <DisplayFeature>[],
    ]) {
      tester.view.displayFeatures = features;
      await tester.pumpAndSettle();
      expect(tester.state<EditableTextState>(find.byType(EditableText)), same(editor));
      expect(editor.widget.controller.text, 'chapter 17');
      expect(tester.takeException(), isNull);
    }
    expect(key.currentState!.handleBack(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
