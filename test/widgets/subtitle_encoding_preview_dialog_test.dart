import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/widgets/video_controls/sheets/subtitle_encoding_preview_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('previews ambiguous text and accepts only the selected encoding', (tester) async {
    final source = <int>[...utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n'), 0xc3, 0xa9];
    final original = List<int>.of(source);
    SubtitleEncodingPreview? selected;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  selected = await showDialog<SubtitleEncodingPreview>(
                    context: context,
                    builder: (_) => SubtitleEncodingPreviewDialog(
                      sourceBytes: source,
                      extension: '.srt',
                      fileName: 'ambiguous.srt',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('é'), findsOneWidget);
    expect(selected, isNull);

    await tester.tap(find.byKey(const ValueKey('subtitle-encoding-preview-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows-1252 · Western European').last);
    await tester.pumpAndSettle();

    expect(find.text('Ã©'), findsOneWidget);
    await tester.tap(find.text('Use this preview'));
    await tester.pumpAndSettle();

    expect(selected?.encoding, 'cp1252');
    expect(selected?.cues.single.text, 'Ã©');
    expect(source, original);
  });

  testWidgets('malformed Unicode stays blocked until the viewer selects a valid legacy encoding', (tester) async {
    final source = <int>[...utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n'), 0xe9];

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      SubtitleEncodingPreviewDialog(sourceBytes: source, extension: '.srt', fileName: 'malformed.srt'),
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
    expect(find.textContaining('malformed'), findsWidgets);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('subtitle-encoding-preview-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows-1252 · Western European').last);
    await tester.pumpAndSettle();

    expect(find.text('é'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });
}
