import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/sources/podcast_actions.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/sources/podcast_opml.dart';
import 'package:plezy/sources/source_controller.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

const _https = 'https://radio.example/secure';
const _firstHttp = 'http://radio.example/city-one/rss?feed=station-one';
const _secondHttp = 'http://radio.example/city-two/rss?feed=station-two';
const _mixed =
    '''
<opml version="2.0"><body>
  <outline title="Secure radio" xmlUrl="$_https"/>
  <outline title="Local radio" xmlUrl="$_firstHttp"/>
  <outline title="Local radio" xmlUrl="$_secondHttp"/>
</body></opml>
''';

class _OpmlPicker extends Fake implements FilePickerDelegate {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(_mixed));
    return FilePickerResult([PlatformFile(name: 'radio.opml', size: bytes.length, bytes: bytes)]);
  }
}

class _Imports extends Fake with ChangeNotifier implements SourceController {
  @override
  int get generation => 3;

  final imports = <List<Uri>>[];
  final approvals = <Set<Uri>>[];

  @override
  void requireSession([int? epoch]) {
    if (epoch != null) expect(epoch, generation);
  }

  @override
  Future<int> importPodcastSubscriptions(
    List<PodcastSubscription> feeds, {
    int? expectedGeneration,
    Set<Uri> approvedHttpFeeds = const {},
  }) async {
    expect(expectedGeneration, generation);
    imports.add([for (final feed in feeds) feed.url]);
    approvals.add(Set.of(approvedHttpFeeds));
    return feeds.length;
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    FilePickerService.setDelegateForTesting(_OpmlPicker());
  });
  tearDown(() => FilePickerService.setDelegateForTesting(null));

  Future<_Imports> openReview(WidgetTester tester) async {
    final imports = _Imports();
    await tester.pumpWidget(
      ChangeNotifierProvider<SourceController>.value(
        value: imports,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  TextButton(onPressed: () => importPodcastOpml(context), child: const Text('Open test OPML')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open test OPML'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Local radio'), findsNWidgets(2));
    expect(find.text('Secure radio'), findsNothing);
    return imports;
  }

  testWidgets('HTTP approvals start unchecked and HTTPS imports when none are selected', (tester) async {
    final imports = await openReview(tester);
    final choices = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(choices.map((tile) => tile.value), [false, false]);
    await tester.tap(find.text(t.podcasts.importOpml));
    await tester.pumpAndSettle();
    expect(imports.imports, [
      [Uri.parse(_https)],
    ]);
    expect(imports.approvals.single, isEmpty);
    expect(find.text(t.podcasts.importSummary(imported: '1', duplicates: '0', skipped: '2')), findsOneWidget);
  });

  testWidgets('approval is limited to the selected feed even when host and title match', (tester) async {
    final imports = await openReview(tester);
    expect(find.textContaining('http://radio.example/city-one/rss'), findsOneWidget);
    expect(find.textContaining('feed=station-one'), findsNothing);
    expect(find.textContaining('feed=station-two'), findsNothing);
    await tester.tap(find.byTooltip(t.startup.showDetails).last);
    await tester.pump();
    expect(find.text(_secondHttp), findsOneWidget);
    expect(find.textContaining('feed=station-one'), findsNothing);
    expect(tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).map((tile) => tile.value), [
      false,
      false,
    ]);
    await tester.tap(find.textContaining('/city-two/rss'));
    await tester.pump();
    expect(tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).map((tile) => tile.value), [false, true]);
    await tester.tap(find.text(t.podcasts.importOpml));
    await tester.pumpAndSettle();
    expect(imports.imports, [
      [Uri.parse(_https), Uri.parse(_secondHttp)],
    ]);
    expect(imports.approvals.single, {Uri.parse(_secondHttp)});
    expect(find.text(t.podcasts.importSummary(imported: '2', duplicates: '0', skipped: '1')), findsOneWidget);
  });

  testWidgets('cancelling the review imports nothing and the next review clears approval', (tester) async {
    final imports = await openReview(tester);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(imports.imports, isEmpty);
    await tester.tap(find.text('Open test OPML'));
    await tester.pumpAndSettle();
    expect(tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).map((tile) => tile.value), [
      false,
      false,
    ]);
    expect(imports.imports, isEmpty);
  });
}
