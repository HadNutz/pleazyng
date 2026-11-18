import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/show_rotation.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/playback_presentation.dart';
import 'package:plezy/sources/comic_reading_list.dart';
import 'package:plezy/sources/source_models.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

class _Renderer extends Fake implements PlayerNative {
  @override
  void Function()? onPresentationChanged;
  final properties = <String, String>{
    'audio-params/channels': 'stereo',
    'audio-out-params/format': 'float',
    'video-target-params/gamma': 'pq',
    'video-params/gamma': 'pq',
    'current-vo': 'gpu-next',
    'current-tracks/sub/codec': 'subrip',
    'sub-hdr-peak': 'auto',
    'hdr-reference-white': '200',
    'display-names': 'OLED',
  };
  int? selected;
  @override
  Future<void> setDualMonoChannel(int? value) async {
    selected = value;
  }

  @override
  Future<String?> getProperty(String name) async => properties[name];
  @override
  Future<void> setProperty(String name, String value) async {
    properties[name] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rounds resume at the unfinished show, preserve series order, and stop at gaps', () {
    episode(String show, int i, {bool watched = false, int? resume}) => testMediaItem(
      id: '$show-$i',
      kind: MediaKind.episode,
      serverId: show,
      grandparentId: show,
      parentIndex: 1,
      index: i,
      viewCount: watched ? 1 : 0,
      viewOffsetMs: resume,
      durationMs: 100000,
    );
    final a = rotationEpisodes([
      episode('a', 1, watched: true),
      episode('a', 2, resume: 12000),
      episode('a', 3),
      episode('a', 5),
    ]);
    expect(a.gap, 4);
    expect(a.episodes.first.viewOffsetMs, 12000);
    final b = [episode('b', 1), episode('b', 2)];
    final initial = rotationRounds({'a': a.episodes, 'b': b, 'finished': []}, [], Random(2));
    expect(initial.map((r) => r.map((e) => e.serverId).toSet()), everyElement({'a', 'b'}));
    final previous = [
      for (final r in initial) [for (final e in r) e.globalKey],
    ];
    final played = initial.first.first.serverId;
    final resumed = rotationRounds(
      {'a': a.episodes.skip(played == 'a' ? 1 : 0).toList(), 'b': b.skip(played == 'b' ? 1 : 0).toList()},
      previous,
      Random(11),
    );
    expect(resumed.expand((r) => r).map((e) => e.globalKey), initial.expand((r) => r).skip(1).map((e) => e.globalKey));
  });

  test('CBL preserves holes, duplicate positions, annuals, decimal issues, and manual candidates', () {
    final list = ComicReadingList.parse(
      utf8.encode(
        '<ReadingList><Name>Crossovers</Name><Books><Book Series="Orbit" Volume="2" Number="1.5"/><Book Series="Orbit Annual" Number="1"/><Book Series="Elsewhere" Number="2"/><Book Series="Orbit Annual" Number="1"/></Books></ReadingList>',
      ),
      'file.cbl',
    );
    expect(ComicReadingList.fromJson(list.toJson()).issues.map((r) => r.series), [
      'Orbit',
      'Orbit Annual',
      'Elsewhere',
      'Orbit Annual',
    ]);
    SourceEntry entry(String source, String file) => SourceEntry(
      sourceId: source,
      id: file,
      title: file,
      kind: SourceItemKind.comic,
      files: [PublicationFile(id: file, name: file, mimeType: "application/vnd.comicbook+zip")],
    );
    final annual = entry('local', 'Orbit Annual #001.cbz'), vol2 = entry('cloud', 'Orbit v2 #01.5.cbz');
    final idx = ComicIssueIndex([annual, vol2, entry('other', 'Orbit v1 #1.5.cbz')]);
    expect(idx.matches(list.issues[0]), [vol2]);
    expect(idx.automatic(list.issues[0], idx.matches(list.issues[0])), vol2);
    expect(idx.matches(list.issues[1]), [annual]);
    expect(idx.matches(list.issues[2]), isEmpty);
    const utf16Xml = '<ReadingList><Books><Book Series="Orbit" Number="2"/></Books></ReadingList>';
    expect(
      ComicReadingList.parse([
        255,
        254,
        for (final c in utf16Xml.codeUnits) ...[c, 0],
      ], 'é.cbl').title,
      'é',
    );
    expect(idx.matches(const ComicIssue('Orbit (Vol. 2)', '1.5')), [vol2]);
    final ambiguous = ComicIssueIndex([annual, entry('komga', 'Orbit Annual #1.cbz')]);
    expect(ambiguous.automatic(list.issues[1], ambiguous.matches(list.issues[1])), isNull);
    expect(() => ComicReadingList.parse(utf8.encode('<!DOCTYPE x><ReadingList/>'), 'bad.cbl'), throwsFormatException);
  });

  test('HDR capability follows the output, codec and property support', () {
    String? control(
      String codec, {
      String output = 'pq',
      String vo = 'gpu-next',
      bool text = true,
      bool bitmap = true,
    }) =>
        hdrSubtitleControl(target: output, source: 'pq', vo: vo, codec: codec, nativeText: text, nativeBitmap: bitmap);
    expect(control('ass'), 'sub-hdr-peak');
    expect(control('subrip', vo: 'libmpv'), 'sub-color');
    expect(control('ass', text: false), isNull);
    expect(control('hdmv_pgs_subtitle', bitmap: false), isNull);
    expect(control('hdmv_pgs_subtitle'), 'image-subs-hdr-peak');
    expect(control('subrip', output: 'bt.1886'), isNull);
    expect(scaledSubtitleColor('#FF0000', 50), '#bc0000');
    expect(scaledSubtitleColor('#88FF0000', 50), '#88bc0000');
    expect(decodedStereo('5.1', 'float'), isFalse);
    expect(decodedStereo('stereo', 'spdif-ac3'), isFalse);
  });

  test('restores original HDR level on SDR and remembers stereo only for the selected file', () async {
    resetSharedPreferencesForTest();
    final renderer = _Renderer();
    var file = 'version-one';
    final service = PlaybackPresentation(renderer, () => (file: file, display: 'screen', stereoSource: true));
    addTearDown(service.dispose);
    Future<void> settle() async {
      service.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }

    await settle();
    await service.chooseBrightness(service.hdrKey!, 50, save: true);
    expect(renderer.properties['sub-hdr-peak'], '100');
    await service.chooseLane(service.stereoKey!, StereoLane.left, save: true);
    expect(renderer.selected, 0);
    await service.chooseLane(service.stereoKey!, StereoLane.right);
    expect(renderer.selected, 1);
    await service.chooseLane(service.stereoKey!, null);
    expect(renderer.selected, 0);
    renderer.properties['display-names'] = 'projector';
    file = 'version-two';
    await settle();
    expect(renderer.selected, isNull);
    expect(renderer.properties['sub-hdr-peak'], 'auto');
    renderer.properties['display-names'] = 'OLED';
    file = 'version-one';
    await settle();
    expect(renderer.selected, 0);
    expect(renderer.properties['sub-hdr-peak'], '100');
    renderer.properties['video-target-params/gamma'] = 'bt.1886';
    renderer.properties['audio-out-params/format'] = 'spdif-ac3';
    await settle();
    expect(service.hdrKey, isNull);
    expect(service.stereoKey, isNull);
    expect(renderer.properties['sub-hdr-peak'], 'auto');
    expect(renderer.selected, isNull);
  });
}
