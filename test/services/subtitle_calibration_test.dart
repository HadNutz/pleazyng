import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/subtitle_calibration_export.dart';
import 'package:plezy/services/subtitle_calibration_history.dart';
import 'package:plezy/services/subtitle_calibration_source.dart';
import 'package:plezy/services/subtitle_retimer.dart';
import 'package:plezy/services/subtitle_sync_calibration.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sidecar reader caps local reads at five MiB', () async {
    final directory = await Directory.systemTemp.createTemp('subtitle_calibration_source_test_');
    try {
      final file = File('${directory.path}/selected.srt');
      await file.writeAsBytes([1, 2, 3]);
      expect(await SubtitleCalibrationSourceReader.read(file.uri), [1, 2, 3]);

      await file.writeAsBytes(List<int>.filled(SubtitleCalibrationSourceReader.maximumBytes + 1, 0));
      await expectLater(SubtitleCalibrationSourceReader.read(file.uri), throwsFormatException);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  String cueId(String value) => List.filled(64, value).join();

  List<SubtitleSyncObservation> cutAnchors() => [
    SubtitleSyncObservation(cueId: cueId('a'), subtitleTimeMs: 60000, playbackTimeMs: 61000),
    SubtitleSyncObservation(cueId: cueId('b'), subtitleTimeMs: 180000, playbackTimeMs: 181000),
    SubtitleSyncObservation(
      cueId: cueId('c'),
      subtitleTimeMs: 240000,
      playbackTimeMs: 220000,
      startsNewSegmentBefore: true,
    ),
    SubtitleSyncObservation(cueId: cueId('d'), subtitleTimeMs: 360000, playbackTimeMs: 340000),
  ];

  test('robust multi-anchor fit rejects cut offsets for native affine settings', () {
    final fit = SubtitleSyncCalibrationFit.fromObservations(cutAnchors());

    expect(fit.calibration.timestampMultiplier, closeTo(1, 1e-9));
    expect(fit.isConsistent, isFalse);
    expect(fit.maximumAbsoluteResidualMs, greaterThan(750));
  });

  test('cue IDs remain stable when the same sidecar is parsed again', () {
    final bytes = utf8.encode('1\n00:01:00,000 --> 00:01:01,000\nStable cue\n');

    final first = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: '.srt');
    final second = SubtitleRetimer.parseCues(sourceBytes: bytes, extension: '.srt');

    expect(first.single.id, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(second.single.id, first.single.id);
  });

  test('piecewise map applies an explicit cut offset without stretching across it', () {
    final mapping = SubtitlePiecewiseClockMap.fromObservations(cutAnchors());

    expect(mapping.rate, closeTo(1, 1e-9));
    expect(mapping.map(120000), 121000);
    expect(mapping.map(240000), 220000);
    expect(mapping.map(300000), 280000);
  });

  test('piecewise WebVTT export preserves BOM, settings, text, line endings and source bytes', () {
    final original = <int>[
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(
        'WEBVTT\r\n\r\n'
        '00:01:00.000 --> 00:01:01.000 align:start\r\nBefore cut\r\n\r\n'
        '00:04:00.000 --> 00:04:01.000 line:90%\r\nAfter cut\r\n',
      ),
    ];
    final mapping = SubtitlePiecewiseClockMap.fromObservations(cutAnchors());
    final result = SubtitleRetimer.retimePiecewise(sourceBytes: original, extension: '.vtt', mapping: mapping);
    final output = utf8.decode(result.bytes);

    expect(result.clippedCueCount, 0);
    expect(output, contains('00:01:01.000 --> 00:01:02.000 align:start\r\nBefore cut'));
    expect(output, contains('00:03:40.000 --> 00:03:41.000 line:90%\r\nAfter cut'));
    expect(result.bytes.take(3).toList(), [0xef, 0xbb, 0xbf]);
    expect(RegExp(r'(?<!\r)\n').hasMatch(output), isFalse); // All output line breaks remain CRLF.
    expect(original.take(3).toList(), [0xef, 0xbb, 0xbf]);
  });

  test('piecewise export clips before-zero cues without mutating the source', () {
    final source = utf8.encode('1\n00:00:02,000 --> 00:00:04,000\nEarly cue\n');
    final anchors = [
      SubtitleSyncObservation(cueId: cueId('e'), subtitleTimeMs: 60000, playbackTimeMs: 1000),
      SubtitleSyncObservation(cueId: cueId('f'), subtitleTimeMs: 180000, playbackTimeMs: 121000),
    ];
    final result = SubtitleRetimer.retimePiecewise(
      sourceBytes: source,
      extension: '.srt',
      mapping: SubtitlePiecewiseClockMap.fromObservations(anchors),
    );

    expect(result.clippedCueCount, 1);
    expect(utf8.decode(result.bytes), isNot(contains('Early cue')));
    expect(utf8.decode(source), contains('Early cue'));
  });

  test('piecewise export refuses cues that span an explicit cut boundary', () {
    final source = utf8.encode('1\n00:03:59,000 --> 00:04:01,000\nCrosses cut\n');

    expect(
      () => SubtitleRetimer.retimePiecewise(
        sourceBytes: source,
        extension: '.srt',
        mapping: SubtitlePiecewiseClockMap.fromObservations(cutAnchors()),
      ),
      throwsFormatException,
    );
  });

  test('calibration identity changes when sidecar bytes or playback scope change', () {
    const original = [1, 2, 3];
    const replacement = [1, 2, 4];
    final first = _identity(SubtitleCalibrationIdentity.digestBytes(original));
    final changedBytes = _identity(SubtitleCalibrationIdentity.digestBytes(replacement));
    final changedLane = _identity(SubtitleCalibrationIdentity.digestBytes(original), lane: 'secondary');
    final changedPart = _identity(SubtitleCalibrationIdentity.digestBytes(original), partId: 'part-2');

    expect(first.storageKey, isNot(changedBytes.storageKey));
    expect(first.storageKey, isNot(changedLane.storageKey));
    expect(first.storageKey, isNot(changedPart.storageKey));
    expect(jsonEncode(first.toSafeJson()), isNot(contains('server-secret')));
    expect(jsonEncode(first.toSafeJson()), isNot(contains('profile-secret')));
  });

  test('export ZIP preserves the exact source and records server identity limits', () {
    final original = utf8.encode(
      '1\n00:01:00,000 --> 00:01:01,000\nCaption\n\n'
      '2\n00:03:00,000 --> 00:03:01,000\nSecond caption\n',
    );
    final cues = SubtitleRetimer.parseCues(sourceBytes: original, extension: '.srt');
    final observations = [
      SubtitleSyncObservation(cueId: cues[0].id, subtitleTimeMs: 60000, playbackTimeMs: 61000),
      SubtitleSyncObservation(cueId: cues[1].id, subtitleTimeMs: 180000, playbackTimeMs: 181000),
    ];
    final mapping = SubtitlePiecewiseClockMap.fromObservations(observations);
    final archiveBytes = SubtitleCalibrationExport.create(
      originalBytes: original,
      fileName: '../../captions.srt',
      extension: '.srt',
      identity: _identity(SubtitleCalibrationIdentity.digestBytes(original)),
      mapping: mapping,
      observations: observations,
      fit: SubtitleSyncCalibrationFit.fromObservations(observations),
      previousRate: 1,
      previousDelayMs: 0,
    );
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    final sourceFile = archive.findFile('original/captions.srt');
    final correctedFile = archive.findFile('corrected/captions.srt');
    final manifestFile = archive.findFile('manifest.json');

    expect(sourceFile, isNotNull);
    expect(sourceFile!.content, original);
    expect(utf8.decode(correctedFile!.content as List<int>), contains('00:01:01,000 --> 00:01:02,000'));
    expect(utf8.decode(manifestFile!.content as List<int>), contains('cannot prove'));

    expect(
      () => SubtitleCalibrationExport.create(
        originalBytes: original,
        fileName: 'captions.srt',
        extension: '.srt',
        identity: _identity(SubtitleCalibrationIdentity.digestBytes(original)),
        mapping: mapping,
        observations: [
          observations.first,
          SubtitleSyncObservation(cueId: cueId('c'), subtitleTimeMs: 180000, playbackTimeMs: 181000),
        ],
        fit: null,
        previousRate: 1,
        previousDelayMs: 0,
      ),
      throwsFormatException,
    );
  });

  group('bounded local history', () {
    late Directory temporary;
    late PathProviderPlatform previous;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('subtitle_calibration_test_');
      previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = FakePathProvider(temporary);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previous;
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    test('history is persisted before an output action and gates that action on I/O failure', () async {
      final bytes = utf8.encode('sidecar-v1');
      final identity = _identity(SubtitleCalibrationIdentity.digestBytes(bytes));
      final anchors = [
        SubtitleSyncObservation(cueId: cueId('a'), subtitleTimeMs: 60000, playbackTimeMs: 61000),
        SubtitleSyncObservation(cueId: cueId('b'), subtitleTimeMs: 180000, playbackTimeMs: 181000),
      ];
      final fit = SubtitleSyncCalibrationFit.fromObservations(anchors);
      final events = <String>[];

      final result = await SubtitleCalibrationHistoryService.saveBeforeAction<String>(
        identity: identity,
        observations: anchors,
        fit: fit,
        previousRate: 1,
        previousDelayMs: 0,
        action: () async {
          events.add('action');
          expect(await SubtitleCalibrationHistoryService.load(identity), hasLength(1));
          return 'completed';
        },
      );
      expect(result, 'completed');
      expect(events, ['action']);

      final blockedRoot = Directory('${temporary.path}/blocked');
      await blockedRoot.create();
      final blockedSupportPath = File('${blockedRoot.path}/support');
      await blockedSupportPath.writeAsString('not a directory');
      PathProviderPlatform.instance = FakePathProvider(blockedRoot);
      var actionCalled = false;
      await expectLater(
        SubtitleCalibrationHistoryService.saveBeforeAction<void>(
          identity: identity,
          observations: anchors,
          fit: fit,
          previousRate: 1,
          previousDelayMs: 0,
          action: () async {
            actionCalled = true;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(actionCalled, isFalse);
    });

    test('history round-trips cue IDs and is separated by exact sidecar bytes', () async {
      final bytes = utf8.encode('sidecar-v1');
      final identity = _identity(SubtitleCalibrationIdentity.digestBytes(bytes));
      final anchors = [
        SubtitleSyncObservation(cueId: cueId('a'), subtitleTimeMs: 60000, playbackTimeMs: 61000),
        SubtitleSyncObservation(cueId: cueId('b'), subtitleTimeMs: 180000, playbackTimeMs: 181000),
      ];
      final fit = SubtitleSyncCalibrationFit.fromObservations(anchors);
      await SubtitleCalibrationHistoryService.save(
        identity: identity,
        observations: anchors,
        fit: fit,
        previousRate: 1,
        previousDelayMs: 0,
      );

      final loaded = await SubtitleCalibrationHistoryService.load(identity);
      final replacedIdentity = _identity(SubtitleCalibrationIdentity.digestBytes(utf8.encode('sidecar-v2')));
      final replaced = await SubtitleCalibrationHistoryService.load(replacedIdentity);
      expect(loaded, hasLength(1));
      expect(loaded.single.fit?.calibration.delayMs, 1000);
      expect(loaded.single.observations.map((anchor) => anchor.cueId), [cueId('a'), cueId('b')]);
      expect(replaced, isEmpty);

      final root = Directory('${temporary.path}/support/subtitle-calibration-history');
      final historyFile = await root
          .list(recursive: true)
          .where((entity) => entity is File && entity.path.endsWith('.json'))
          .cast<File>()
          .first;
      final encoded = await historyFile.readAsString();
      expect(encoded, isNot(contains('profile-secret')));
      expect(encoded, isNot(contains('server-secret')));
    });
  });
}

SubtitleCalibrationIdentity _identity(String sourceDigest, {String lane = 'primary', String partId = 'part-1'}) =>
    SubtitleCalibrationIdentity(
      profileId: 'profile-secret',
      serverId: 'server-secret',
      ratingKey: 'item-secret',
      mediaIndex: 1,
      partId: partId,
      partOffsetMs: 120000,
      audioTrackIdentity: 'audio-stream-5',
      subtitleTrackIdentity: 'subtitle-stream-8',
      lane: lane,
      sourceBytesDigest: sourceDigest,
    );
